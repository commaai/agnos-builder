#!/bin/bash -e

# Make sure we're in the correct directory
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
cd $DIR

# Constants
OTA_DIR="$DIR/../output/ota"
DATA_ACCOUNT="commadist"

# Parse input
source $DIR/upload.sh

process_file() {
  local NAME=$1
  local HASH=$(cat $OTA_JSON | jq -r ".[] | select(.name == \"$NAME\") | .hash_raw")
  local FILE_NAME="$NAME-$HASH.img.xz"
  local CLOUD_PATH="https://$DATA_ACCOUNT.blob.core.windows.net/$DATA_CONTAINER/$FILE_NAME"

  echo "Copying $NAME to the cloud..."
  azcopy cp --overwrite=false $OTA_DIR/$FILE_NAME "$CLOUD_PATH?$DATA_SAS_TOKEN"
  echo "  $CLOUD_PATH"

  # if [ "$NAME" == "system" ]; then
  #   local CAIBX_FILE_NAME="system-$HASH.caibx"
  #   local CHUNKS_FOLDER="system-$HASH"

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

# Generate token
echo "Logging in..."
SAS_EXPIRY=$(date -u '+%Y-%m-%dT%H:%M:%SZ' -d '+1 hour')
DATA_SAS_TOKEN=$(az storage container generate-sas --as-user --auth-mode login --account-name $DATA_ACCOUNT --name $DATA_CONTAINER --https-only --permissions wr --expiry $SAS_EXPIRY --output tsv)

# Liftoff!
process_file "system"
process_file "boot"
process_file "abl"
process_file "xbl"
process_file "xbl_config"
process_file "devcfg"
process_file "aop"

echo "Done!"
