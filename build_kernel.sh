#!/bin/bash -e

DEFCONFIG=tici_defconfig

# Get directories and make sure we're in the correct spot to start the build
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
TOOLS=$DIR/tools
TMP_DIR=/tmp/agnos-builder-tmp
OUTPUT_DIR=$DIR/output
BOOT_IMG=./boot.img
cd $DIR

# Clone kernel if not done already
if git submodule status --cached agnos-kernel-sdm845/ | grep "^-"; then
  git submodule update --init agnos-kernel-sdm845
fi
cd agnos-kernel-sdm845

# Build parameters
ARCH=$(uname -m)
if [ "$ARCH" != "arm64" ] && [ "$ARCH" != "aarch64" ]; then
  export CROSS_COMPILE=$TOOLS/aarch64-linux-gnu-gcc/bin/aarch64-linux-gnu-
  export CC=$TOOLS/aarch64-linux-gnu-gcc/bin/aarch64-linux-gnu-gcc
  export LD=$TOOLS/aarch64-linux-gnu-gcc/bin/aarch64-linux-gnu-ld.bfd

  $DIR/tools/extract_tools.sh
fi
export ARCH=arm64

# these do anything?
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
