#!/usr/bin/env bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
cd $DIR

DOWNLOADED="aop abl xbl xbl_config devcfg"
scripts/download-from-manifest.py --manifest firmware.json
for part in $DOWNLOADED; do
  tools/edl w ${part}_a $DIR/output/$part.img
  tools/edl w ${part}_b $DIR/output/$part.img
done

./flash_kernel.sh
./flash_system.sh
