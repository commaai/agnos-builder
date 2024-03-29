#!/bin/bash -e
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
cd $DIR

echo "Flashing system..."
{
  $EDL setactive a
  $EDL setbootablestoragedrive 1
  $EDL e system_a --memory=ufs
  $EDL w system_a $DIR/output/system-skip-chunks.img --memory=ufs
  $EDL reset
} > /dev/null

echo "Done!"
