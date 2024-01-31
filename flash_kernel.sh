#!/bin/bash -e

# Config
OUTPUT_DIR="output"
KERNEL_IMAGE="boot.img"

# Log colors
GREEN="\033[0;32m"
NO_COLOR='\033[0m'

# Flash bootloader
$EDL w boot_a $OUTPUT_DIR/$KERNEL_IMAGE
$EDL w boot_b $OUTPUT_DIR/$KERNEL_IMAGE

echo -e "${GREEN}Done!"
