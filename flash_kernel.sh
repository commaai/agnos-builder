#!/usr/bin/env bash
set -e

GREEN="\033[0;32m"
NO_COLOR='\033[0m'

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
cd $DIR

echo "Flashing kernel..."
tools/edl w boot_a output/boot.img
tools/edl w boot_b output/boot.img

echo -e "${GREEN}Flashed boot_a and boot_b!${NO_COLOR}"
