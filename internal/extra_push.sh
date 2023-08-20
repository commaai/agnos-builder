#!/bin/bash -e

# Make sure we're in the correct directory
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
cd $DIR

# Constants
OTA_OUTPUT_DIR="$DIR/../output/ota"

source upload.sh

# Liftoff!
for NAME in $(cat $EXTRA_JSON | jq -r '.[] | .name'); do
  local HASH_RAW=$(cat $EXTRA_JSON | jq -r ".[] | select(.name == \"$NAME\") | .hash_raw")
  local SPARSE=$(cat $EXTRA_JSON | jq -r ".[] | select(.name == \"$NAME\") | .sparse")

  if [ "$SPARSE" == "true" ]; then
    upload_file "$NAME-$HASH_RAW-skip-chunks.img.gz"
  else
    upload_file "$NAME-$HASH_RAW.img.gz"
  fi
done

echo "Done!"
