#!/bin/bash
set -e

# TODO: Install base packages with xbps
echo "base_setup.sh: TODO - install xbps packages"

# Create comma user
useradd -m -s /bin/bash comma || true
echo "comma ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/comma

# Basic setup
mkdir -p /data /system
