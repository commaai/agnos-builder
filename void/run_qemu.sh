#!/usr/bin/env bash
set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null && pwd)"

DEFAULT_ROOTFS="$ROOT_DIR/build/system.img"
SPARSE_ROOTFS="$ROOT_DIR/output/system.img"

KERNEL_IMAGE_DEFAULT="$ROOT_DIR/agnos-kernel-sdm845/out-qemu/arch/arm64/boot/Image"
KERNEL_IMAGE="${KERNEL_IMAGE:-$KERNEL_IMAGE_DEFAULT}"
ROOTFS_IMAGE="${ROOTFS_IMAGE:-$DEFAULT_ROOTFS}"
INITRD_IMAGE="${INITRD_IMAGE:-}"
QEMU_BIN="${QEMU_BIN:-qemu-system-aarch64}"

MEM="${MEM:-2048}"
SMP="${SMP:-4}"
SSH_PORT="${SSH_PORT:-2222}"
EXTRA_QEMU_ARGS="${EXTRA_QEMU_ARGS:-}"
EXTRA_KERNEL_ARGS="${EXTRA_KERNEL_ARGS:-}"

usage() {
  cat <<'EOF'
Usage: ./void/run_qemu.sh

Environment overrides:
  KERNEL_IMAGE       Path to arm64 Image (default: agnos-kernel-sdm845/out-qemu/...)
  ROOTFS_IMAGE       Path to ext4 image (default: build/system.img)
  INITRD_IMAGE       Optional initrd path to load
  QEMU_BIN           qemu-system-aarch64 binary
  MEM                RAM in MB (default: 2048)
  SMP                vCPU count (default: 4)
  SSH_PORT           Host port forwarded to guest :22 (default: 2222, set 0 to disable)
  EXTRA_QEMU_ARGS    Extra args passed to QEMU
  EXTRA_KERNEL_ARGS  Extra kernel cmdline args
EOF
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

if ! command -v "$QEMU_BIN" >/dev/null 2>&1; then
  echo "Missing $QEMU_BIN. Install qemu-system-aarch64 or set QEMU_BIN."
  exit 1
fi

if [ ! -f "$ROOTFS_IMAGE" ]; then
  if [ -f "$SPARSE_ROOTFS" ]; then
    if command -v simg2img >/dev/null 2>&1; then
      mkdir -p "$ROOT_DIR/build"
      simg2img "$SPARSE_ROOTFS" "$ROOTFS_IMAGE"
    else
      echo "Rootfs not found at $ROOTFS_IMAGE."
      echo "Run ./void/build_void.sh or install simg2img to convert $SPARSE_ROOTFS."
      exit 1
    fi
  else
    echo "Rootfs not found. Run ./void/build_void.sh first."
    exit 1
  fi
fi

if [ ! -f "$KERNEL_IMAGE" ]; then
  echo "Kernel image not found at $KERNEL_IMAGE."
  echo "Build one with ./void/build_qemu_kernel.sh or set KERNEL_IMAGE."
  exit 1
fi

if [ -n "$INITRD_IMAGE" ] && [ ! -f "$INITRD_IMAGE" ]; then
  echo "Initrd not found at $INITRD_IMAGE."
  exit 1
fi

if [[ "$KERNEL_IMAGE" == *"/out/arch/arm64/boot/Image" ]]; then
  echo "Note: using the device kernel; QEMU virt may not boot. Prefer out-qemu."
fi

KERNEL_CMDLINE="root=/dev/vda rw rootfstype=ext4 rootwait console=ttyAMA0 loglevel=7 ${EXTRA_KERNEL_ARGS}"
INITRD_ARGS=""
if [ -n "$INITRD_IMAGE" ]; then
  INITRD_ARGS="-initrd $INITRD_IMAGE"
fi
NETDEV_ARGS="-netdev user,id=net0"
if [ -n "$SSH_PORT" ] && [ "$SSH_PORT" != "0" ]; then
  NETDEV_ARGS="-netdev user,id=net0,hostfwd=tcp::${SSH_PORT}-:22"
fi

exec "$QEMU_BIN" \
  -machine virt \
  -cpu cortex-a57 \
  -m "$MEM" \
  -smp "$SMP" \
  -nographic \
  -kernel "$KERNEL_IMAGE" \
  $INITRD_ARGS \
  -append "$KERNEL_CMDLINE" \
  -drive file="$ROOTFS_IMAGE",format=raw,if=virtio \
  -device virtio-net-pci,netdev=net0 \
  $NETDEV_ARGS \
  ${EXTRA_QEMU_ARGS}
