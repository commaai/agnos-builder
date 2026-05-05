#!/usr/bin/env bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
cd $DIR

scripts/mdma.py reboot-qdl --missing-ok
tools/qdl flash system $DIR/output/system.img
tools/qdl reset
scripts/mdma.py reboot --missing-ok
