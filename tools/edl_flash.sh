#!/bin/bash -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
ROOT=$DIR/..

EDL=$ROOT/edl/edl

if [ $# -ne 2 ]; then
  echo "Not enough number of arguments. Requires 2 arguments: <flash_partition> <flash_file>"
  exit 1
fi

$EDL w $1 $2 --memory=ufs
