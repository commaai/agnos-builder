#!/bin/bash -e

# Make sure we're in the correct directory
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
cd $DIR

# Constants
# TODO: get these from package_ota.sh
OTA_DIR="$DIR/../output/ota"
TOOLS_DIR="$DIR/../tools"

AGNOS_UPDATE_URL=${AGNOS_UPDATE_URL:-https://commadist.azureedge.net/agnosupdate}
AGNOS_STAGING_UPDATE_URL=${AGNOS_STAGING_UPDATE_URL:-https://commadist.azureedge.net/agnosupdate-staging}
OTA_JSON="$OTA_DIR/ota.json"
OTA_STAGING_JSON="$OTA_DIR/ota-staging.json"
EXTRA_JSON="$OTA_DIR/extra.json"
EXTRA_STAGING_JSON="$OTA_DIR/extra-staging.json"

process_file() {
  local NAME=$1
  echo "Processing $NAME..."

  local IMAGE_CONFIG=$(cat $OTA_JSON | jq -r ".[] | select(.name == \"$NAME\")")
  local URL=$(echo "$IMAGE_CONFIG" | jq -r ".url")
  local HASH=$(echo "$IMAGE_CONFIG" | jq -r ".hash")
  local HASH_RAW=$(echo "$IMAGE_CONFIG" | jq -r ".hash_raw")
  local SPARSE=$(echo "$IMAGE_CONFIG" | jq -r ".sparse")
  local FULL_CHECK=$(echo "$IMAGE_CONFIG" | jq -r ".full_check")
  local HAS_AB=$(echo "$IMAGE_CONFIG" | jq -r ".has_ab")

  local FILE_NAME="$NAME-$HASH_RAW.img"
  local IMAGE_FILE="$OTA_DIR/$FILE_NAME"
  if [ ! -f $IMAGE_FILE ]; then
    local XZ_FILE="$IMAGE_FILE.xz"
    if [ ! -f "$XZ_FILE" ]; then
      echo "  downloading..."
      wget -O $XZ_FILE $URL &> /dev/null
    fi

    echo "  decompressing..."
    xz --decompress --stdout $XZ_FILE > $IMAGE_FILE
  fi

  echo "  verifying hash..."
  local ACTUAL_HASH=$(sha256sum $IMAGE_FILE | cut -c 1-64)
  if [ "$ACTUAL_HASH" != "$HASH" ]; then
    echo "$NAME hash mismatch!" >&2
    echo "  Expected: $HASH" >&2
    echo "  Actual:   $ACTUAL_HASH" >&2
    exit 1
  fi

  if [ $SPARSE == "true" ] && [ $NAME == "system" ]; then
    local OPTIMIZED_IMAGE_FILE=${IMAGE_FILE%.img}-optimized.img
    if [ ! -f "$OPTIMIZED_IMAGE_FILE" ]; then
      echo "  optimizing..."
      $TOOLS_DIR/simg2dontcare.py $IMAGE_FILE $OPTIMIZED_IMAGE_FILE
    fi
    IMAGE_FILE=$OPTIMIZED_IMAGE_FILE
    HASH=$(sha256sum $IMAGE_FILE | cut -c 1-64)
  fi

  local GZ_FILE_NAME="$FILE_NAME.gz"
  local GZ_FILE="$OTA_DIR/$GZ_FILE_NAME"
  if [ ! -f "$GZ_FILE" ]; then
    echo "  compressing..."
    gzip -c $IMAGE_FILE > $GZ_FILE
  fi

  local SIZE=$(wc -c < $IMAGE_FILE)
  cat <<EOF >> $EXTRA_JSON
  {
    "name": "$NAME",
    "url": "$AGNOS_UPDATE_URL/$GZ_FILE_NAME",
    "hash": "$HASH",
    "hash_raw": "$HASH_RAW",
    "size": $SIZE,
    "sparse": $SPARSE,
    "full_check": $FULL_CHECK,
    "has_ab": $HAS_AB
  },
EOF
  cat <<EOF >> $EXTRA_STAGING_JSON
  {
    "name": "$NAME",
    "url": "$AGNOS_STAGING_UPDATE_URL/$GZ_FILE_NAME",
    "hash": "$HASH",
    "hash_raw": "$HASH_RAW",
    "size": $SIZE,
    "sparse": $SPARSE,
    "full_check": $FULL_CHECK,
    "has_ab": $HAS_AB
  },
EOF
}

cd $ROOT
mkdir -p $OTA_DIR

# If given a manifest URL, download and use that
if [ ! -z "$1" ]; then
  OTA_JSON=$(mktemp)
  echo "Using provided manifest..."
  wget -O $OTA_JSON $1 &> /dev/null
else
  echo "Using master AGNOS manifest..."
  wget -O $OTA_JSON https://raw.githubusercontent.com/commaai/openpilot/master/system/hardware/tici/ota.json &> /dev/null
fi

echo "[" > $EXTRA_JSON
echo "[" > $EXTRA_STAGING_JSON

for image in $(cat $OTA_JSON | jq -r '.[] | .name'); do
  process_file $image
done

# remove trailing comma
sed -i "$ s/.$//" $EXTRA_JSON
sed -i "$ s/.$//" $EXTRA_STAGING_JSON

echo "]" >> $EXTRA_JSON
echo "]" >> $EXTRA_STAGING_JSON

echo "Done!"
