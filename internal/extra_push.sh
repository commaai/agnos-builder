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
for NAME in $(cat $EXTRA_JSON | jq -r '.[] | .name'); do
  local HASH_RAW=$(cat $EXTRA_JSON | jq -r ".[] | select(.name == \"$NAME\") | .hash_raw")
  upload_file "$NAME-$HASH_RAW.img.gz"
done

echo "Done!"
