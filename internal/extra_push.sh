#!/bin/bash -e

# Make sure we're in the correct directory
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
cd $DIR

# Constants
# TODO: get these from package_ota.sh
OTA_DIR="$DIR/../output/ota"
DATA_ACCOUNT="commadist"

source $DIR/upload.sh

# Liftoff!
for name in $(cat $EXTRA_JSON | jq -r '.[] | .name'); do
  local hash_raw=$(cat $EXTRA_JSON | jq -r ".[] | select(.name == \"$name\") | .hash_raw")
  upload_file "$name-$hash_raw.img.gz"
done

echo "Done!"
