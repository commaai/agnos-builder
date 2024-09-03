#!/usr/bin/env bash
set -e

DEFCONFIG=tici_defconfig

# Get directories and make sure we're in the correct spot to start the build
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
TOOLS=$DIR/tools
TMP_DIR=/tmp/agnos-builder-tmp
OUTPUT_DIR=$DIR/output
BOOT_IMG=./boot.img
cd $DIR

if [[ "$(uname)" == 'Darwin' ]]; then
  BASE_VOLUME_PATH=$(echo $DIR | grep -o "^/Volumes/[^/]*" || echo "/")
  if ! diskutil info -plist $BASE_VOLUME_PATH | grep -q "<string>Case-sensitive APFS</string>"; then
    echo "---------------   macOS support   ---------------"
    echo "Ensure you are in a Case-sensitive APFS volume to build the AGNOS kernel."
    echo "https://github.com/commaai/agnos-builder?tab=readme-ov-file#macos"
    echo "-------------------------------------------------"
    exit 1
  fi
fi

# Setup kernel build container
echo "Building agnos-meta-builder docker image"
export DOCKER_BUILDKIT=1
docker build -f Dockerfile.builder -t agnos-meta-builder $DIR \
  --build-arg UNAME=$(id -nu) \
  --build-arg UID=$(id -u) \
  --build-arg GID=$(id -g)
echo "Starting agnos-meta-builder container"
CONTAINER_ID=$(docker run -d -v $DIR:$DIR -w $DIR agnos-meta-builder)

# Cleanup container on exit
trap "echo \"Cleaning up container:\"; \
docker container rm -f $CONTAINER_ID" EXIT

# Clone kernel if not done already
if git submodule status --cached agnos-kernel-sdm845/ | grep "^-"; then
  echo "Cloning agnos-kernel-sdm845"
  git submodule update --init agnos-kernel-sdm845
fi

$DIR/tools/extract_tools.sh

build_kernel() {
  cd agnos-kernel-sdm845

  # Build parameters
  ARCH=$(uname -m)
  if [ "$ARCH" != "arm64" ] && [ "$ARCH" != "aarch64" ]; then
    export CROSS_COMPILE=$TOOLS/aarch64-linux-gnu-gcc/bin/aarch64-linux-gnu-
    export CC=$TOOLS/aarch64-linux-gnu-gcc/bin/aarch64-linux-gnu-gcc
    export LD=$TOOLS/aarch64-linux-gnu-gcc/bin/aarch64-linux-gnu-ld.bfd
  fi

  # Build arm64 arch
  export ARCH=arm64

  # Set ccache dir
  export CCACHE_DIR=$DIR/.ccache

  # Avoid LINUX_COMPILE_HOST to change on every run thus invalidating cache
  # https://patchwork.kernel.org/project/linux-kbuild/patch/1302015561-21047-8-git-send-email-mmarek@suse.cz/
  export KBUILD_BUILD_HOST="docker"

  # Disable all warnings
  export KCFLAGS="-w"

  # Load defconfig and build kernel
  echo "-- First make --"
  make $DEFCONFIG O=out
  echo "-- Second make: $(nproc --all) cores --"
  make -j$(nproc --all) O=out  # Image.gz-dtb

  # Turn on if you want perf
  # LDFLAGS=-static make -j$(nproc --all) -C tools/perf

  # Copy over Image.gz-dtb
  mkdir -p $TMP_DIR
  cd $TMP_DIR
  cp $DIR/agnos-kernel-sdm845/out/arch/arm64/boot/Image.gz-dtb .

  # Make boot image
  $TOOLS/mkbootimg \
    --kernel Image.gz-dtb \
    --ramdisk /dev/null \
    --cmdline "console=ttyMSM0,115200n8 quiet loglevel=3 earlycon=msm_geni_serial,0xA84000 androidboot.hardware=qcom androidboot.console=ttyMSM0 ehci-hcd.park=3 lpm_levels.sleep_disabled=1 service_locator.enable=1 androidboot.selinux=permissive firmware_class.path=/lib/firmware/updates net.ifnames=0 dyndbg=\"\"" \
    --pagesize 4096 \
    --base 0x80000000 \
    --kernel_offset 0x8000 \
    --ramdisk_offset 0x8000 \
    --tags_offset 0x100 \
    --output $BOOT_IMG.nonsecure

  # le signing
  openssl dgst -sha256 -binary $BOOT_IMG.nonsecure > $BOOT_IMG.sha256
  openssl pkeyutl -sign -in $BOOT_IMG.sha256 -inkey $DIR/vble-qti.key -out $BOOT_IMG.sig -pkeyopt digest:sha256 -pkeyopt rsa_padding_mode:pkcs1
  dd if=/dev/zero of=$BOOT_IMG.sig.padded bs=2048 count=1
  dd if=$BOOT_IMG.sig of=$BOOT_IMG.sig.padded conv=notrunc
  cat $BOOT_IMG.nonsecure $BOOT_IMG.sig.padded > $BOOT_IMG

  # Copy to output dir
  mkdir -p $OUTPUT_DIR
  mv $BOOT_IMG $OUTPUT_DIR/
  cp $DIR/agnos-kernel-sdm845/out/techpack/audio/asoc/snd-soc-sdm845.ko $OUTPUT_DIR/
  cp $DIR/agnos-kernel-sdm845/out/techpack/audio/asoc/codecs/snd-soc-wcd9xxx.ko $OUTPUT_DIR/
  cp $DIR/agnos-kernel-sdm845/out/drivers/staging/qcacld-3.0/wlan.ko $OUTPUT_DIR/
}

# Run build_kernel in container
docker exec -u $(id -nu) $CONTAINER_ID bash -c "set -e; export DEFCONFIG=$DEFCONFIG DIR=$DIR TOOLS=$TOOLS TMP_DIR=$TMP_DIR OUTPUT_DIR=$OUTPUT_DIR BOOT_IMG=$BOOT_IMG; $(declare -f build_kernel); build_kernel"
