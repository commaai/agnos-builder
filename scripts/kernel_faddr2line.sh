#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"/..
KERNEL_DIR="$ROOT_DIR/build/linux"

exec docker run --rm -i -v "$ROOT_DIR:$ROOT_DIR" -w "$ROOT_DIR" \
  --entrypoint bash agnos-mainline-builder -c '
set -euo pipefail
if [[ "$(uname -m)" != aarch64 && "$(uname -m)" != arm64 ]]; then
  export CROSS_COMPILE=aarch64-linux-gnu-
fi
exec "$1/scripts/faddr2line" "$2" "${@:3}"
' bash "$KERNEL_DIR" "$ROOT_DIR/build/kernel-out/vmlinux" "$@"
