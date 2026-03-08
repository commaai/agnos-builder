#!/usr/bin/env bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
cd $DIR

echo "Checking active slot..."
ACTIVE_SLOT=$(tools/qdl getactiveslot)

if [[ "$ACTIVE_SLOT" != "a" && "$ACTIVE_SLOT" != "b" ]]; then
  echo "Invalid active slot: '$ACTIVE_SLOT'"
  exit 1
fi

echo "Active slot: $ACTIVE_SLOT"
echo "Flashing boot_$ACTIVE_SLOT..."
tools/qdl flash boot_$ACTIVE_SLOT $DIR/output/boot.img

echo "Flashed boot_$ACTIVE_SLOT!"
