#!/bin/bash -e
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
cd $DIR

echo "Flashing system..."
tools/edl w system_a $DIR/output/system-skip-chunks.img

tools/edl setactiveslot a
tools/edl setbootablestoragedrive 1

echo "Done!"
