#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

SOURCE_DIR="$DIR/kernel/linux"
KERNEL_DIR="$DIR/build/linux"
OUT_DIR="$DIR/build/kernel-out"
SPECTRA_DIR="$DIR/build/spectra-camera"
OUTPUT_DIR="$DIR/output"
TOOLS="$DIR/tools"

if [[ "$(uname)" == Darwin ]]; then
  BASE_VOLUME_PATH=$(echo "$DIR" | grep -o "^/Volumes/[^/]*" || echo "/")
  if ! diskutil info -plist "$BASE_VOLUME_PATH" | grep -q "<string>Case-sensitive APFS</string>"; then
    echo "Ensure you are in a Case-sensitive APFS volume to build the AGNOS kernel."
    echo "https://github.com/commaai/agnos-builder?tab=readme-ov-file#macos"
    exit 1
  fi
fi

if [ ! -f "$SOURCE_DIR/Makefile" ]; then
  git submodule update --init kernel/linux
fi
if [ ! -f "$DIR/kernel/spectra/kernel/spectra-camera/Kbuild" ]; then
  git submodule update --init kernel/spectra
fi

# Build the pinned upstream tree plus our patches, keeping the submodule clean.
# The separate output directory preserves incremental build artifacts.
SOURCE_ID=$({
  git -C "$SOURCE_DIR" rev-parse HEAD
  git -C "$DIR/kernel/spectra" rev-parse HEAD
  shasum -a 256 kernel/patches/*.patch kernel/dts/*
} | shasum -a 256 | cut -d ' ' -f 1)
if [ "$(cat "$KERNEL_DIR/.agnos-source" 2>/dev/null || true)" != "$SOURCE_ID" ]; then
  rm -rf "$KERNEL_DIR"
  mkdir -p "$KERNEL_DIR"
  git -C "$SOURCE_DIR" archive HEAD | tar -xf - -C "$KERNEL_DIR"
  git -C "$KERNEL_DIR" init -q
  for patch in "$DIR"/kernel/patches/*.patch; do
    git -C "$KERNEL_DIR" apply --check --whitespace=error "$patch"
    git -C "$KERNEL_DIR" apply --whitespace=error "$patch"
  done
  cp kernel/dts/* "$KERNEL_DIR/arch/arm64/boot/dts/qcom/"
  echo "$SOURCE_ID" > "$KERNEL_DIR/.agnos-source"
fi

SPECTRA_ID=$(git -C "$DIR/kernel/spectra" rev-parse HEAD)
if [ "$(cat "$SPECTRA_DIR/.agnos-source" 2>/dev/null || true)" != "$SPECTRA_ID" ]; then
  rm -rf "$SPECTRA_DIR"
  mkdir -p "$SPECTRA_DIR"
  git -C "$DIR/kernel/spectra" archive HEAD kernel/spectra-camera | \
    tar -xf - --strip-components=2 -C "$SPECTRA_DIR"
  echo "$SPECTRA_ID" > "$SPECTRA_DIR/.agnos-source"
fi

docker build -f Dockerfile.builder -t agnos-mainline-builder . \
  --build-arg UNAME="$(id -nu)" --build-arg UID="$(id -u)" --build-arg GID="$(id -g)"

build_kernel() {
  export ARCH=arm64
  export CROSS_COMPILE=""
  if [[ "$(uname -m)" != aarch64 && "$(uname -m)" != arm64 ]]; then
    export CROSS_COMPILE=aarch64-linux-gnu-
  fi
  export CCACHE_DIR="$DIR/.ccache"
  export KBUILD_BUILD_USER=comma
  export KBUILD_BUILD_HOST=agnos
  export LOCALVERSION=-agnos

  cd "$KERNEL_DIR"
  local args=(O="$OUT_DIR" CC="ccache ${CROSS_COMPILE}gcc" HOSTCC="ccache gcc" HOSTCXX="ccache g++")
  make "${args[@]}" defconfig
  KCONFIG_CONFIG="$OUT_DIR/.config" scripts/kconfig/merge_config.sh -m -y \
    "$OUT_DIR/.config" "$DIR/kernel/configs/mici.config"
  make "${args[@]}" olddefconfig
  make -j"$(nproc)" "${args[@]}" Image qcom/sdm845-comma-mici.dtb modules
  make -j"$(nproc)" "${args[@]}" M="$SPECTRA_DIR" modules

  local tmp="$DIR/build/boot"
  mkdir -p "$tmp" "$OUTPUT_DIR"
  python3 - "$OUT_DIR/arch/arm64/boot/Image" \
    "$OUT_DIR/arch/arm64/boot/dts/qcom/sdm845-comma-mici.dtb" "$tmp/Image-dtb" <<'PY'
import struct
import sys
from pathlib import Path

image = Path(sys.argv[1]).read_bytes()
dtb = Path(sys.argv[2]).read_bytes()
Path(sys.argv[3]).write_bytes(b"UNCOMPRESSED_IMG" + struct.pack("<I", len(image)) + image + dtb)
PY
  python3 "$TOOLS/mkbootimg" \
    --kernel "$tmp/Image-dtb" --ramdisk /dev/null \
    --cmdline 'console=ttyMSM0,115200n8 isolcpus=6,7 earlycon=msm_geni_serial,0xA84000 androidboot.hardware=qcom androidboot.console=ttyMSM0 firmware_class.path=/lib/firmware/updates net.ifnames=0' \
    --pagesize 4096 --base 0x80000000 --kernel_offset 0x8000 \
    --ramdisk_offset 0x8000 --tags_offset 0x100 --output "$tmp/boot.img.nonsecure"

  openssl dgst -sha256 -binary "$tmp/boot.img.nonsecure" > "$tmp/boot.img.sha256"
  openssl pkeyutl -sign -in "$tmp/boot.img.sha256" -inkey "$DIR/vble-qti.key" \
    -out "$tmp/boot.img.sig" -pkeyopt digest:sha256 -pkeyopt rsa_padding_mode:pkcs1
  dd if=/dev/zero of="$tmp/boot.img.sig.padded" bs=2048 count=1 status=none
  dd if="$tmp/boot.img.sig" of="$tmp/boot.img.sig.padded" conv=notrunc status=none
  cat "$tmp/boot.img.nonsecure" "$tmp/boot.img.sig.padded" > "$OUTPUT_DIR/boot.img"

  rm -rf "$OUTPUT_DIR/linux-headers"
  make "${args[@]}" headers_install INSTALL_HDR_PATH="$OUTPUT_DIR/linux-headers"
  cp -a "$SPECTRA_DIR/uapi/." "$OUTPUT_DIR/linux-headers/include/"
  rm -rf "$OUTPUT_DIR/kernel-modules"
  make "${args[@]}" modules_install INSTALL_MOD_PATH="$OUTPUT_DIR/kernel-modules" INSTALL_MOD_STRIP=1
  make "${args[@]}" M="$SPECTRA_DIR" modules_install \
    INSTALL_MOD_PATH="$OUTPUT_DIR/kernel-modules" INSTALL_MOD_STRIP=1
  find "$OUTPUT_DIR/kernel-modules" -type l -name build -delete
  python3 "$DIR/kernel/package_modules.py" "$OUTPUT_DIR/kernel-modules" \
    --report "$OUTPUT_DIR/modules-mici.json"
}

docker run --rm -i -u "$(id -u):$(id -g)" -v "$DIR:$DIR" -w "$DIR" \
  --entrypoint bash agnos-mainline-builder <<EOF
set -euo pipefail
DIR='$DIR'
KERNEL_DIR='$KERNEL_DIR'
OUT_DIR='$OUT_DIR'
SPECTRA_DIR='$SPECTRA_DIR'
OUTPUT_DIR='$OUTPUT_DIR'
TOOLS='$TOOLS'
$(declare -f build_kernel)
build_kernel
EOF
