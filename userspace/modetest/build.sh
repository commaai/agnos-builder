#!/usr/bin/env bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"

cd $DIR


if [ ! -d libdrm/ ]; then
  git clone https://github.com/grate-driver/libdrm
fi
cd libdrm
git fetch --all
git checkout 3e3c53e
git reset --hard
git clean -xdff .
