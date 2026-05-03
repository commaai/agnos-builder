#!/bin/bash

# Skip while Docker is assembling the image.
if [ -f /.dockerenv ]; then
  exit 0
fi

sudo mount -o ro,remount / || true
