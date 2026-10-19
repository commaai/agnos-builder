#!/bin/bash

# Skip unless this is a booted systemd system.
if [ ! -d /run/systemd/system ]; then
  exit 0
fi

sudo mount -o ro,remount / || true
