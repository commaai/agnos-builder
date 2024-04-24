#!/bin/bash -e

GREEN="\033[0;32m"
NO_COLOR='\033[0m'

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
cd $DIR

echo "Flashing bootloader..."
tools/edl w abl_a output/abl.elf
tools/edl w abl_b output/abl.elf

echo -e "${GREEN}Flashed abl_a and abl_b!${NO_COLOR}"
