#!/usr/bin/env bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
cd $DIR

# Custom firehose loader with USB 3.0 SuperSpeed support
CUSTOM_LOADER="$DIR/tools/edl_repo/Loaders/qualcomm/factory/sdm845_sdm850_sda845/prog_firehose_ddr_usb3.elf"

# Use custom loader if it exists, otherwise let EDL auto-select
if [[ -f "$CUSTOM_LOADER" ]]; then
  LOADER_ARG="--loader=$CUSTOM_LOADER"
  echo "Using custom USB 3.0 loader: $CUSTOM_LOADER"
else
  LOADER_ARG=""
  echo "Custom loader not found, using default loader"
fi

echo "Checking active slot..."
#ACTIVE_SLOT=$(tools/edl getactiveslot | grep "Current active slot:" | awk '{print $NF}')
ACTIVE_SLOT="a"

if [[ "$ACTIVE_SLOT" != "a" && "$ACTIVE_SLOT" != "b" ]]; then
  echo "Invalid active slot: '$ACTIVE_SLOT'"
  exit 1
fi

echo "Active slot: $ACTIVE_SLOT"
echo "Flashing system_$ACTIVE_SLOT..."
#tools/edl w system_$ACTIVE_SLOT $DIR/output/system.img $LOADER_ARG

#tools/edl reset $LOADER_ARG

fastboot flash system_a $DIR/output/system.img
fastboot --set-active=a
fastboot continue

echo "Flashed system_$ACTIVE_SLOT!"
