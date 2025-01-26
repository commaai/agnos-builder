#!/usr/bin/env bash
set -e

# sudo apt install ncdu
sudo ncdu build/agnos-rootfs/ || true
