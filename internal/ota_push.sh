#!/bin/bash -e

# Make sure we're in the correct directory
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
cd $DIR

# Constants
OTA_DIR="$DIR/../output/ota"
DATA_ACCOUNT="commadist"

source $DIR/upload.sh

process_file() {
  local NAME=$1
  local HASH_RAW=$(cat $OTA_JSON | jq -r ".[] | select(.name == \"$NAME\") | .hash_raw")
  upload_file "$NAME-$HASH_RAW.img.xz"

  # if [ "$NAME" == "system" ]; then
  #   local CAIBX_FILE_NAME="system-$HASH_RAW.caibx"
  #   local CHUNKS_FOLDER="system-$HASH_RAW"

  #   echo "Copying system.caibx to the cloud..."
  #   local SYSTEM_CAIBX_PATH="https://$DATA_ACCOUNT.blob.core.windows.net/$DATA_CONTAINER/$CAIBX_FILE_NAME"
  #   azcopy cp --overwrite=false $OTA_DIR/$CAIBX_FILE_NAME "$SYSTEM_CAIBX_PATH?$DATA_SAS_TOKEN"
  #   echo "  $SYSTEM_CAIBX_PATH"

  #   echo "Copying system chunks to the cloud..."
  #   local SYSTEM_CHUNKS_PATH="https://$DATA_ACCOUNT.blob.core.windows.net/$DATA_CONTAINER"
  #   azcopy cp --recursive --overwrite=false $OTA_DIR/$CHUNKS_FOLDER "$SYSTEM_CHUNKS_PATH?$DATA_SAS_TOKEN"
  #   echo "  $SYSTEM_CHUNKS_PATH"
  # fi
}

# Liftoff!
for name in $(cat $OTA_JSON | jq -r ".[] .name"); do
  process_file $name
done

echo "Done!"
