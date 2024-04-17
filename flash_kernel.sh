#!/bin/bash
set -e

# Log colors
GREEN="\033[0;32m"
NO_COLOR='\033[0m'

# Make sure we're in the correct spot
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
cd $DIR

# Flash bootloader
echo "Flashing kernel..."
tools/edl w boot_a output/boot.img
tools/edl w boot_b output/boot.img

echo -e "${GREEN}Done!"
