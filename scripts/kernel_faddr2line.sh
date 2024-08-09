#!/usr/bin/env bash

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"/..
TOOLS=$ROOT_DIR/tools
KERNEL_DIR=$ROOT_DIR/agnos-kernel-sdm845
CROSS_COMPILE=$TOOLS/aarch64-linux-gnu-gcc/bin/aarch64-linux-gnu-

$KERNEL_DIR/scripts/faddr2line $KERNEL_DIR/out/vmlinux $1

