#!/bin/bash -e

# Make sure we're in the correct directory
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
cd $DIR

# Constants
OTA_DIR="$DIR/../output/ota"
DATA_ACCOUNT="${DATA_ACCOUNT:-commadist}"

# Parse input
if [ "$1" == "production" ]; then
  OTA_JSON="$OTA_DIR/ota.json"
  DATA_CONTAINER="agnosupdate"
elif [ "$1" == "staging" ]; then
  OTA_JSON="$OTA_DIR/ota-staging.json"
  DATA_CONTAINER="agnosupdate-staging"
elif [ "$1" == "ci" ] && [ -n "$2" ]; then
  OTA_JSON="$OTA_DIR/ota.json"
  DATA_CONTAINER="agnosupdate-ci"
  FOLDER_NAME="$2/"
else
  echo "Supply either 'production' or 'staging' or 'ci' as first argument!"
  exit 1
fi

upload_file() {
  local FILE_NAME=$1
  local CLOUD_PATH="https://$DATA_ACCOUNT.blob.core.windows.net/$DATA_CONTAINER/$FOLDER_NAME$FILE_NAME"

  echo "Uploading $FILE_NAME to Azure..."

  az storage blob upload \
    --account-name $DATA_ACCOUNT \
    --container-name $DATA_CONTAINER \
    --name "$FOLDER_NAME$FILE_NAME" \
    --file "$OTA_DIR/$FILE_NAME" \
    --auth-mode login \
    --overwrite false

  echo "  $CLOUD_PATH"
}

process_file() {
  local NAME=$1
  local HASH_RAW=$(cat $OTA_JSON | jq -r ".[] | select(.name == \"$NAME\") | .hash_raw")
  upload_file "$NAME-$HASH_RAW.img.xz"

  local ALT_URL=$(cat $OTA_JSON | jq -r ".[] | select(.name == \"$NAME\") | .alt.url")
  if [ "$ALT_URL" != "null" ]; then
    local ALT_FILE_NAME=$(basename $ALT_URL)
    upload_file $ALT_FILE_NAME
  fi

  # TODO: replace with "az storage blob upload-batch" - not using azcopy in GitHub CI
  # https://learn.microsoft.com/en-us/cli/azure/storage/blob?view=azure-cli-latest#az-storage-blob-upload-batch
  #
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

# Upload
for name in $(cat $OTA_JSON | jq -r ".[] .name"); do
  process_file $name
done

echo "Done!"
