#!/bin/bash

# Skip inside the image builder.
if [ ! -d /run/runit ]; then
  exit 0
fi

sudo mount -o ro,remount / || true
