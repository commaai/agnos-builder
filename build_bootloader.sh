#!/bin/bash -e

# Get directories and make sure we're in the correct spot to start the build
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
OUTPUT_DIR=$DIR/output
cd $DIR

# Clone bootloader if not done already
if [ ! -d edk2_tici ]; then
  git submodule init edk2_tici
fi
cd edk2_tici

# Create output directory
mkdir -p $OUTPUT_DIR

# Run build
./build.sh

# Copy output
cp out/* $OUTPUT_DIR/
