#!/bin/bash -e
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
cd $DIR


edl setactiveslot a
edl e system_a
fastboot --set-active=a
fastboot erase system_a
fastboot flash system_a $DIR/output/system-skip-chunks.img
fastboot continue

echo "Done!"
