#!/bin/bash -e

# for all the non-essential nice to haves

apt-get update && apt-get install -y --no-install-recommends \
  irqtop \
  ripgrep
