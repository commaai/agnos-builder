#!/bin/bash -e
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
cd $DIR

$EDL setactive a
$EDL e system_a
$EDL w system_a $DIR/output/system-skip-chunks.img

$EDL reset

echo "Done!"
