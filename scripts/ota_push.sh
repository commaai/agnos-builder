#!/usr/bin/env bash
set -e

# Make sure we're in the correct directory
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
cd $DIR

# Constants
OTA_DIR="$DIR/../output/ota"
DATA_ACCOUNT="commadist"

# Parse input
FOUND=0
if [ "$1" == "production" ]; then
  OTA_JSON="$OTA_DIR/ota.json"
  DATA_CONTAINER="agnosupdate"
  FOUND=1
fi
if [ "$1" == "staging" ]; then
  OTA_JSON="$OTA_DIR/ota-staging.json"
  DATA_CONTAINER="agnosupdate-staging"
  FOUND=1
fi

if [ $FOUND == 0 ]; then
  echo "Supply either 'production' or 'staging' as first argument!"
  exit 1
fi

upload_file() {
  local FILE_NAME=$1
  local CLOUD_PATH="https://$DATA_ACCOUNT.blob.core.windows.net/$DATA_CONTAINER/$FILE_NAME"

  echo "Copying $FILE_NAME to the cloud..."
  azcopy cp --log-level ERROR --overwrite=false $OTA_DIR/$FILE_NAME "$CLOUD_PATH?$DATA_SAS_TOKEN"
  echo "  $CLOUD_PATH"
}

process_file() {
  local NAME=$1
  local HASH_RAW=$(cat $OTA_JSON | jq -r ".[] | select(.name == \"$NAME\") | .hash_raw")
  upload_file "$NAME-$HASH_RAW.img.xz"
}

# Generate token
echo "Logging in..."
SAS_EXPIRY=$(date -u '+%Y-%m-%dT%H:%M:%SZ' -d '+1 hour')
DATA_SAS_TOKEN=$(az storage container generate-sas --as-user --auth-mode login --account-name $DATA_ACCOUNT --name $DATA_CONTAINER --https-only --permissions wr --expiry $SAS_EXPIRY --output tsv)

# Liftoff!
for name in $(cat $OTA_JSON | jq -r ".[] .name"); do
  if grep -q "name.*${name}" $DIR/../firmware.json; then
    echo "Skipping $name, found in firmware.json"
  else
    process_file $name
  fi
done

echo "Done!"
