#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

root_dir="userspace/root"
deb_dir="userspace/debs"

rm -rf "$root_dir"
mkdir -p "$root_dir"

for deb in "$deb_dir"/*.deb; do
  echo "unpacking $deb"
  dpkg-deb -x "$deb" "$root_dir"
done
