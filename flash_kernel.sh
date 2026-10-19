#!/usr/bin/env bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
cd $DIR

scripts/mdma.py --missing-ok reboot-qdl
tools/qdl flash boot $DIR/output/boot.img
# Leave the device in QDL so flash_system.sh can run next without an MDMA.
