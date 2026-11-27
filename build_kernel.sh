#!/usr/bin/env bash
set -e

export DEFCONFIG=comma_defconfig
export DTBS="sdm845-comma-mici sdm845-comma-tizi"
export CMDLINE="console=ttyMSM0,115200n8 isolcpus=6,7 quiet loglevel=3 earlycon firmware_class.path=/firmware/image net.ifnames=0 reboot=warm fw_devlink.sync_state=timeout"

export DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
export TOOLS=$DIR/tools
export SRC_DIR=$DIR/build/linux
export OUT_DIR=$DIR/build/kernel-out
export SPECTRA_DIR=$DIR/build/spectra-camera
export OUTPUT_DIR=$DIR/output
cd $DIR

if [[ "$(uname)" == 'Darwin' ]]; then
  BASE_VOLUME_PATH=$(echo $DIR | grep -o "^/Volumes/[^/]*" || echo "/")
  if ! diskutil info -plist $BASE_VOLUME_PATH | grep -q "<string>Case-sensitive APFS</string>"; then
    echo "Ensure you are in a Case-sensitive APFS volume to build the AGNOS kernel."
    echo "https://github.com/commaai/agnos-builder?tab=readme-ov-file#macos"
    exit 1
  fi
fi

git submodule update --init --depth 1 kernel/linux

# Patched kernel source, regenerated only when the pin, patches, DTS or config change.
# Objects live in $OUT_DIR, so a regenerated source tree still builds incrementally.
SOURCE_ID=$(cat <(git -C kernel/linux rev-parse HEAD) kernel/patches/*.patch kernel/dts/* kernel/configs/* | sha256sum)
if [ "$(cat $SRC_DIR/.agnos-source 2>/dev/null)" != "$SOURCE_ID" ]; then
  echo "Preparing kernel source"
  rm -rf $SRC_DIR
  mkdir -p $SRC_DIR
  git -C kernel/linux archive HEAD | tar -x -C $SRC_DIR
  git -C $SRC_DIR init -q
  git -C $SRC_DIR apply --whitespace=error $DIR/kernel/patches/*.patch
  cp kernel/dts/* $SRC_DIR/arch/arm64/boot/dts/qcom/
  cp kernel/configs/$DEFCONFIG $SRC_DIR/arch/arm64/configs/
  echo "$SOURCE_ID" > $SRC_DIR/.agnos-source
fi

rm -rf $SPECTRA_DIR
mkdir -p $SPECTRA_DIR
cp -a kernel/spectra/. $SPECTRA_DIR

# Reproducible: timestamp the build with the kernel pin's commit date
export KBUILD_BUILD_TIMESTAMP="$(git -C kernel/linux log -1 --format=%cd)"

echo "Building agnos-kernel-builder docker image"
export DOCKER_BUILDKIT=1
docker build -f Dockerfile.builder -t agnos-kernel-builder $DIR \
  --build-arg UNAME=$(id -nu) \
  --build-arg UID=$(id -u) \
  --build-arg GID=$(id -g)

build_kernel() {
  export ARCH=arm64
  if [ "$(uname -m)" != "aarch64" ]; then
    export CROSS_COMPILE=aarch64-linux-gnu-
  fi
  export CCACHE_DIR=$DIR/.ccache
  export KBUILD_BUILD_USER=comma
  export KBUILD_BUILD_HOST=agnos
  export LOCALVERSION=-agnos
  local make=(make -C $SRC_DIR O=$OUT_DIR "CC=ccache ${CROSS_COMPILE}gcc")
  local dtbs=$(for d in $DTBS; do echo qcom/$d.dtb; done)

  "${make[@]}" $DEFCONFIG
  "${make[@]}" -j$(nproc) Image modules $dtbs
  "${make[@]}" -j$(nproc) M=$SPECTRA_DIR modules

  # The bootloader picks the appended DTB whose qcom,board-id matches the device
  local boot=$DIR/build/boot
  local image=$OUT_DIR/arch/arm64/boot/Image
  mkdir -p $boot $OUTPUT_DIR
  python3 -c "import os, struct, sys; sys.stdout.buffer.write(b'UNCOMPRESSED_IMG' + struct.pack('<I', os.path.getsize(sys.argv[1])))" $image > $boot/Image-dtb
  (cat $image; cd $OUT_DIR/arch/arm64/boot/dts && cat $dtbs) >> $boot/Image-dtb

  python3 $TOOLS/mkbootimg \
    --kernel $boot/Image-dtb \
    --ramdisk /dev/null \
    --cmdline "$CMDLINE" \
    --pagesize 4096 \
    --base 0x80000000 \
    --kernel_offset 0x8000 \
    --ramdisk_offset 0x8000 \
    --tags_offset 0x100 \
    --output $boot/boot.img.nonsecure

  # le signing
  openssl dgst -sha256 -binary $boot/boot.img.nonsecure > $boot/boot.img.sha256
  openssl pkeyutl -sign -in $boot/boot.img.sha256 -inkey $DIR/vble-qti.key -out $boot/boot.img.sig -pkeyopt digest:sha256 -pkeyopt rsa_padding_mode:pkcs1
  dd if=/dev/zero of=$boot/boot.img.sig.padded bs=2048 count=1 status=none
  dd if=$boot/boot.img.sig of=$boot/boot.img.sig.padded conv=notrunc status=none
  cat $boot/boot.img.nonsecure $boot/boot.img.sig.padded > $OUTPUT_DIR/boot.img

  echo "-- Install kernel UAPI headers and modules --"
  rm -rf $OUTPUT_DIR/linux-headers $OUTPUT_DIR/kernel-modules
  "${make[@]}" headers_install INSTALL_HDR_PATH=$OUTPUT_DIR/linux-headers
  cp -a $SPECTRA_DIR/uapi/. $OUTPUT_DIR/linux-headers/include/
  "${make[@]}" modules_install INSTALL_MOD_PATH=$OUTPUT_DIR/kernel-modules INSTALL_MOD_STRIP=1
  "${make[@]}" M=$SPECTRA_DIR modules_install INSTALL_MOD_PATH=$OUTPUT_DIR/kernel-modules INSTALL_MOD_STRIP=1
  find $OUTPUT_DIR/kernel-modules -type l -name build -delete
}

docker run --rm -u $(id -u):$(id -g) -v $DIR:$DIR -w $DIR --entrypoint bash \
  -e DIR -e TOOLS -e SRC_DIR -e OUT_DIR -e SPECTRA_DIR -e OUTPUT_DIR \
  -e DEFCONFIG -e DTBS -e CMDLINE -e KBUILD_BUILD_TIMESTAMP \
  agnos-kernel-builder -c "set -e; $(declare -f build_kernel); build_kernel"
