#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
cd $DIR

echo "Flashing kernel..."
tools/edl w boot_a $DIR/output/boot.img

echo "Done!"
