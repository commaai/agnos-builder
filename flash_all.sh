#!/usr/bin/env bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
cd $DIR

scripts/mdma.py reboot-qdl --missing-ok

for part in aop abl xbl xbl_config devcfg; do
  tools/qdl flash ${part}_a $DIR/firmware/$part.img
  tools/qdl flash ${part}_b $DIR/firmware/$part.img
done

tools/qdl flash boot $DIR/output/boot.img
tools/qdl flash system $DIR/output/system.img
tools/qdl reset

scripts/mdma.py reboot --missing-ok
