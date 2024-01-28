#!/bin/bash -e
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
cd $DIR

EDL_DIR=$DIR/edl
if [ ! -d  $EDL_DIR ]; then
  ./install_edl.sh
fi

$EDL_DIR/edl setactive a
$EDL_DIR/edl e system_a
$EDL_DIR/edl w system_a $DIR/output/system-skip-chunks.img

$EDL_DIR/edl reset

echo "Done!"
