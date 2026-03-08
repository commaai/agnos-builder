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
echo "Flashing system_$ACTIVE_SLOT..."
$QDL flash system_$ACTIVE_SLOT $DIR/output/system.img

$QDL reset

echo "Flashed system_$ACTIVE_SLOT!"
