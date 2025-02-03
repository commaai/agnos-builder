#!/usr/bin/env bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
cd $DIR

for part in aop abl xbl xbl_config devcfg; do
  tools/edl w ${part}_a $DIR/firmware/$part.img
  tools/edl w ${part}_b $DIR/firmware/$part.img
done

./flash_kernel.sh
./flash_system.sh
