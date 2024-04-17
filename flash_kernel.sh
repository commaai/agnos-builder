#!/bin/bash -e

# Config
OUTPUT_DIR="output"
KERNEL_IMAGE="boot.img"

# Log colors
GREEN="\033[0;32m"
NO_COLOR='\033[0m'

# Make sure we're in the correct spot
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
cd $DIR

source $DIR/tools/setup_edl_commands.sh

# Flash bootloader
echo "Flashing kernel..."
flash boot_a $OUTPUT_DIR/$KERNEL_IMAGE
flash boot_b $OUTPUT_DIR/$KERNEL_IMAGE

echo -e "${GREEN}Done!"
