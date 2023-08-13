#!/bin/bash -e

# Make sure we're in the correct directory
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
cd $DIR

# Constants
# TODO: get these from package_ota.sh
OTA_DIR="$DIR/../output/ota"
DATA_ACCOUNT="commadist"

# Parse input
source $DIR/upload.sh

process_file() {
  local NAME=$1
  local HASH_RAW=$(cat $EXTRA_JSON | jq -r ".[] | select(.name == \"$NAME\") | .hash_raw")
  local FILE_NAME="$NAME-$HASH_RAW.img.gz"
  local CLOUD_PATH="https://$DATA_ACCOUNT.blob.core.windows.net/$DATA_CONTAINER/$FILE_NAME"

  echo "Copying $NAME to the cloud..."
  azcopy cp --overwrite=false $OTA_DIR/$FILE_NAME "$CLOUD_PATH?$DATA_SAS_TOKEN"
  echo "  $CLOUD_PATH"
}

# Generate token
echo "Logging in..."
SAS_EXPIRY=$(date -u '+%Y-%m-%dT%H:%M:%SZ' -d '+1 hour')
DATA_SAS_TOKEN=$(az storage container generate-sas --as-user --auth-mode login --account-name $DATA_ACCOUNT --name $DATA_CONTAINER --https-only --permissions wr --expiry $SAS_EXPIRY --output tsv)

# Liftoff!
for image in $(cat $EXTRA_JSON | jq -r '.[] | .name'); do
  process_file $image
done

echo "Done!"
