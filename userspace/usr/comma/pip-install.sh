#!/usr/bin/bash
set -e

sudo mount -o rw,remount /

sudo $(which pip) install "$@"
sudo $(which pyenv) rehash

sudo mount -o ro,remount / || true
