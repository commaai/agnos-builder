#!/usr/bin/env bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
cd $DIR

echo "Checking active slot..."
ACTIVE_SLOT=$(tools/edl getactiveslot | grep "Current active slot:" | awk '{print $NF}')

if [[ "$ACTIVE_SLOT" != "a" && "$ACTIVE_SLOT" != "b" ]]; then
  echo "Invalid active slot: '$ACTIVE_SLOT'"
  exit 1
fi

echo "Active slot: $ACTIVE_SLOT"
echo "Flashing system_$ACTIVE_SLOT..."
tools/edl w system_$ACTIVE_SLOT $DIR/output/system.img

tools/edl reset

echo "Flashed system_$ACTIVE_SLOT!"
