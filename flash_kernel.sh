#!/usr/bin/env bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
cd $DIR

if ! command -v bun &> /dev/null; then
  echo "Installing bun..."
  curl -fsSL https://bun.sh/install | bash
  export PATH="$HOME/.bun/bin:$PATH"
fi

QDL="bunx --bun commaai/qdl.js"

echo "Checking active slot..."
ACTIVE_SLOT=$($QDL getactiveslot)

if [[ "$ACTIVE_SLOT" != "a" && "$ACTIVE_SLOT" != "b" ]]; then
  echo "Invalid active slot: '$ACTIVE_SLOT'"
  exit 1
fi

echo "Active slot: $ACTIVE_SLOT"
echo "Flashing boot_$ACTIVE_SLOT..."
$QDL flash boot_$ACTIVE_SLOT $DIR/output/boot.img

echo "Flashed boot_$ACTIVE_SLOT!"
