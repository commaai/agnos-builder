#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
cd $DIR/..

./build_kernel.sh
./build_system.sh
scripts/package_ota.py

# push to azure on an internal machine
if [ "$USER" == "batman" ]; then
  scripts/ota_push.sh staging
fi
