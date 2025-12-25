#!/usr/bin/env bash
set -e

DEFCONFIG=${DEFCONFIG:-defconfig}
OUT_DIR=${OUT_DIR:-out-qemu}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null && pwd)"
KERNEL_DIR="$ROOT_DIR/agnos-kernel-sdm845"
TOOLS="$ROOT_DIR/tools"

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  cat <<'EOF'
Usage: DEFCONFIG=defconfig OUT_DIR=out-qemu ./void/build_qemu_kernel.sh

Builds an arm64 kernel Image suitable for QEMU's "virt" machine.
Override DEFCONFIG or OUT_DIR if needed.
EOF
  exit 0
fi

# Ensure the kernel submodule exists.
if git submodule status --cached agnos-kernel-sdm845/ | grep "^-"; then
  git submodule update --init agnos-kernel-sdm845
fi

"$TOOLS/extract_tools.sh"

ARCH=$(uname -m)
if [ "$ARCH" != "arm64" ] && [ "$ARCH" != "aarch64" ]; then
  export CROSS_COMPILE="$TOOLS/aarch64-linux-gnu-gcc/bin/aarch64-linux-gnu-"
  export CC="$TOOLS/aarch64-linux-gnu-gcc/bin/aarch64-linux-gnu-gcc"
  export LD="$TOOLS/aarch64-linux-gnu-gcc/bin/aarch64-linux-gnu-ld.bfd"
fi

export ARCH=arm64
export KCFLAGS="-w"

make -C "$KERNEL_DIR" "$DEFCONFIG" O="$OUT_DIR"
make -C "$KERNEL_DIR" -j"$(nproc --all)" O="$OUT_DIR" Image

echo "Kernel image: $KERNEL_DIR/$OUT_DIR/arch/arm64/boot/Image"
