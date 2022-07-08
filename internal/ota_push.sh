#!/bin/bash -e

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

# Read update file
SYSTEM_HASH=$(cat $OTA_JSON | jq -r ".[] | select(.name == \"system\") | .hash_raw")
echo "Found system hash: $SYSTEM_HASH"
BOOT_HASH=$(cat $OTA_JSON | jq -r ".[] | select(.name == \"boot\") | .hash_raw")
echo "Found boot hash: $BOOT_HASH"
ABL_HASH=$(cat $OTA_JSON | jq -r ".[] | select(.name == \"abl\") | .hash_raw")
echo "Found abl hash: $ABL_HASH"
XBL_HASH=$(cat $OTA_JSON | jq -r ".[] | select(.name == \"xbl\") | .hash_raw")
echo "Found xbl hash: $XBL_HASH"
XBL_CONFIG_HASH=$(cat $OTA_JSON | jq -r ".[] | select(.name == \"xbl_config\") | .hash_raw")
echo "Found xbl_config hash: $XBL_CONFIG_HASH"

# Generate token
echo "Logging in..."
SAS_EXPIRY=$(date -u '+%Y-%m-%dT%H:%M:%SZ' -d '+1 hour')
DATA_SAS_TOKEN=$(az storage container generate-sas --as-user --auth-mode login --account-name $DATA_ACCOUNT --name $DATA_CONTAINER --https-only --permissions wr --expiry $SAS_EXPIRY --output tsv)

# Liftoff!
SYSTEM_FILE_NAME="system-$SYSTEM_HASH.img.xz"
SYSTEM_CAIBX_FILE_NAME="system-$SYSTEM_HASH.caibx"
SYSTEM_CHUNKS_FOLDER="system-$SYSTEM_HASH"
BOOT_FILE_NAME="boot-$BOOT_HASH.img.xz"
ABL_FILE_NAME="abl-$ABL_HASH.img.xz"
XBL_FILE_NAME="xbl-$XBL_HASH.img.xz"
XBL_CONFIG_FILE_NAME="xbl_config-$XBL_CONFIG_HASH.img.xz"

echo "Copying system to the cloud..."
SYSTEM_CLOUD_PATH="https://$DATA_ACCOUNT.blob.core.windows.net/$DATA_CONTAINER/$SYSTEM_FILE_NAME"
azcopy cp --overwrite=false $OTA_DIR/$SYSTEM_FILE_NAME "$SYSTEM_CLOUD_PATH?$DATA_SAS_TOKEN"

echo "Copying system.caibx to the cloud..."
SYSTEM_CAIBX_PATH="https://$DATA_ACCOUNT.blob.core.windows.net/$DATA_CONTAINER/$SYSTEM_CAIBX_FILE_NAME"
azcopy cp --overwrite=false $OTA_DIR/$SYSTEM_CAIBX_FILE_NAME "$SYSTEM_CAIBX_PATH?$DATA_SAS_TOKEN"

echo "Copying system casync chunks to the cloud..."
SYSTEM_CHUNKS_PATH="https://$DATA_ACCOUNT.blob.core.windows.net/$DATA_CONTAINER"
azcopy cp --recursive=true --overwrite=false $OTA_DIR/$SYSTEM_CHUNKS_FOLDER "$SYSTEM_CHUNKS_PATH?$DATA_SAS_TOKEN"

echo "Copying boot to the cloud..."
BOOT_CLOUD_PATH="https://$DATA_ACCOUNT.blob.core.windows.net/$DATA_CONTAINER/$BOOT_FILE_NAME"
azcopy cp --overwrite=false $OTA_DIR/$BOOT_FILE_NAME "$BOOT_CLOUD_PATH?$DATA_SAS_TOKEN"

echo "Copying abl to the cloud..."
ABL_CLOUD_PATH="https://$DATA_ACCOUNT.blob.core.windows.net/$DATA_CONTAINER/$ABL_FILE_NAME"
azcopy cp --overwrite=false $OTA_DIR/$ABL_FILE_NAME "$ABL_CLOUD_PATH?$DATA_SAS_TOKEN"

echo "Copying xbl to the cloud..."
XBL_CLOUD_PATH="https://$DATA_ACCOUNT.blob.core.windows.net/$DATA_CONTAINER/$XBL_FILE_NAME"
azcopy cp --overwrite=false $OTA_DIR/$XBL_FILE_NAME "$XBL_CLOUD_PATH?$DATA_SAS_TOKEN"

echo "Copying xbl_config to the cloud..."
XBL_CONFIG_CLOUD_PATH="https://$DATA_ACCOUNT.blob.core.windows.net/$DATA_CONTAINER/$XBL_CONFIG_FILE_NAME"
azcopy cp --overwrite=false $OTA_DIR/$XBL_CONFIG_FILE_NAME "$XBL_CONFIG_CLOUD_PATH?$DATA_SAS_TOKEN"

echo "Done!"
echo "  System path: $SYSTEM_CLOUD_PATH"
echo "  Boot path: $BOOT_CLOUD_PATH"
echo "  abl path: $ABL_CLOUD_PATH"
echo "  xbl path: $XBL_CLOUD_PATH"
echo "  xbl_config path: $XBL_CONFIG_CLOUD_PATH"
