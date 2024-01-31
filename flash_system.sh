#!/bin/bash -e
set -e

$EDL setactive a
$EDL e system_a
$EDL w system_a $DIR/output/system-skip-chunks.img

$EDL reset

echo "Done!"
