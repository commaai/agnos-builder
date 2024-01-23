#!/bin/bash -e

# Config
OUTPUT_DIR="output"
BOOTLOADER_IMAGE="abl.elf"

# Log colors
GREEN="\033[0;32m"
NO_COLOR='\033[0m'

# Make sure we're in the correct spot
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
cd $DIR

# Flash bootloader
edl w abl_a $OUTPUT_DIR/$BOOTLOADER_IMAGE
edl w abl_b $OUTPUT_DIR/$BOOTLOADER_IMAGE

echo -e "${GREEN}Done!"
