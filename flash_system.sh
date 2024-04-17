#!/bin/bash -e
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
cd $DIR

source $DIR/tools/setup_edl_commands.sh

setactiveslot a

echo "Flashing system..."
flash system_a $DIR/output/system-skip-chunks.img

echo "Done!"
