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
OTA_JSON="$OTA_OUTPUT_DIR/ota.json"
OTA_STAGING_JSON="$OTA_OUTPUT_DIR/ota-staging.json"
EXTRA_JSON="$OTA_OUTPUT_DIR/extra.json"
EXTRA_STAGING_JSON="$OTA_OUTPUT_DIR/extra-staging.json"

process_file() {
  local NAME=$1
  local HASH_RAW=$(cat $OTA_JSON | jq -r ".[] | select(.name == \"$NAME\") | .hash_raw")

  local IMAGE_FILE="$OTA_DIR/$NAME-$HASH_RAW.img"
  local GZ_FILE="$IMAGE_FILE.gz"

  if [ ! -f "$IMAGE_FILE" ]; then
    local XZ_FILE="$IMAGE_FILE.xz"
    if [ ! -f "$XZ_FILE" ]; then
      local URL=$(cat $OTA_JSON | jq -r ".[] | select(.name == \"$NAME\") | .url")
      echo "Downloading $NAME..."
      wget -O $XZ_FILE $URL
    fi

    echo "Decompressing $NAME..."
    xz --decompress --stdout $XZ_FILE > $IMAGE_FILE
  fi

  local ACTUAL_HASH_RAW=$(sha256sum $IMAGE_FILE | cut -c 1-64)
  if [ "$ACTUAL_HASH_RAW" != "$HASH_RAW" ]; then
    echo "$NAME hash mismatch!"
    echo "  Expected: $HASH_RAW"
    echo "  Actual:   $ACTUAL_HASH_RAW"
    exit 1
  fi

  if [ $NAME == "system" ]; then
    local OPTIMIZED_IMAGE_FILE=${IMAGE_FILE%.img}-optimized.img
    if [ ! -f "$OPTIMIZED_IMAGE_FILE" ]; then
      echo "Optimizing $NAME..."
      $TOOLS_DIR/simg2dontcare.py $IMAGE_FILE $OPTIMIZED_IMAGE_FILE
    fi

    # TODO: output
  fi

  if [ ! -f "$GZ_FILE" ]; then
    echo "Compressing $NAME..."
    gzip -c $IMAGE_FILE > $GZ_FILE

    # TODO: output
  fi
}

cd $ROOT

echo "[" > $EXTRA_JSON
echo "[" > $EXTRA_STAGING_JSON

for image in $(cat $OTA_JSON | jq -r '.[] | .name'); do
  process_file $image
done

# remove trailing comma
sed -i '$ s/.$//' $OUTPUT_JSON
sed -i '$ s/.$//' $OUTPUT_STAGING_JSON

echo "]" >> $OUTPUT_JSON
echo "]" >> $OUTPUT_STAGING_JSON

echo "Done!"
