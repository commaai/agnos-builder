#!/bin/bash -e

# Log colors
GREEN="\033[0;32m"
NO_COLOR='\033[0m'

# Make sure we're in the correct spot
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
cd $DIR

echo "Flashing bootloader..."
tools/edl w abl_a output/abl.elf
tools/edl w abl_b output/abl.elf

echo -e "${GREEN}Done!"
