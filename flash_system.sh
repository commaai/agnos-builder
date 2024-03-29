#!/bin/bash -e
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
cd $DIR
EDL=$DIR/edl/edl

echo "Setting slot a active..."
{
  $EDL setactive a
  $EDL setbootablestoragedrive 1
} &> /dev/null

echo "Flashing system..."
$EDL w system_a $DIR/output/system-skip-chunks.img --memory=ufs

$EDL reset &> /dev/null

echo "Done!"
