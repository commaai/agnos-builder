#!/bin/bash -e

# Make sure we're in the correct spot
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"

ROOT="$DIR/../"
TMP_DIR="/tmp/agnos-builder-tmp"
OUTPUT_DIR="$ROOT/output"
OTA_OUTPUT_DIR="$OUTPUT_DIR/ota"
FIRMWARE_DIR="$ROOT/agnos-firmware"

AGNOS_UPDATE_URL=${AGNOS_UPDATE_URL:-https://commadist.azureedge.net/agnosupdate}
AGNOS_STAGING_UPDATE_URL=${AGNOS_STAGING_UPDATE_URL:-https://commadist.azureedge.net/agnosupdate-staging}
OUTPUT_JSON="$OTA_OUTPUT_DIR/ota.json"
OUTPUT_STAGING_JSON="$OTA_OUTPUT_DIR/ota-staging.json"

# Make sure archive dir is empty
rm -rf $OTA_OUTPUT_DIR && mkdir -p $OTA_OUTPUT_DIR

process_file() {
  local FILE=$1
  local NAME=$(basename $1 .img)

  echo "Hashing $NAME..."
  local HASH=$(sha256sum $FILE | cut -c 1-64)
  local SIZE=$(wc -c < $FILE)
  echo "  $HASH ($SIZE bytes)"

  local HASH_RAW=$HASH
  if [ "$NAME" == "system" ]; then
    echo "Converting $NAME to raw..."
    local FILE_RAW=/tmp/$NAME.img.raw
    simg2img $FILE $FILE_RAW

    echo "Hashing $NAME raw..."
    HASH_RAW=$(sha256sum $FILE_RAW | cut -c 1-64)
    echo "  $HASH_RAW"

    # echo "Creating $NAME casync files"
    # casync make --compression=xz --store $OTA_OUTPUT_DIR/$NAME-$HASH $OTA_OUTPUT_DIR/$NAME-$HASH.caibx $FILE_RAW

    rm $FILE_RAW
  fi

  echo "Compressing $NAME..."
  local ARCHIVE=$OTA_OUTPUT_DIR/$NAME-$HASH.img.xz
  xz -vc $FILE > $ARCHIVE

  local URL=$AGNOS_UPDATE_URL/$NAME-$HASH.img.xz
  local STAGING_URL=$AGNOS_STAGING_UPDATE_URL/$NAME-$HASH.img.xz

  echo "  {" >> $OUTPUT_JSON
  echo "    \"name\": \"$NAME\"," >> $OUTPUT_JSON
  echo "    \"url\": \"$URL\"," >> $OUTPUT_JSON
  echo "    \"hash\": \"$HASH\"," >> $OUTPUT_JSON
  echo "    \"hash_raw\": \"$HASH_RAW\"," >> $OUTPUT_JSON
  echo "    \"size\": $SIZE," >> $OUTPUT_JSON
  echo "    \"sparse\": false," >> $OUTPUT_JSON
  echo "    \"full_check\": true," >> $OUTPUT_JSON
  echo "    \"has_ab\": true" >> $OUTPUT_JSON
  # echo "    \"casync_caibx\": \"$AGNOS_UPDATE_URL/$NAME-$HASH.caibx\"," >> $OUTPUT_JSON
  # echo "    \"casync_store\": \"$AGNOS_UPDATE_URL/$NAME-$HASH\"" >> $OUTPUT_JSON
  echo "  }," >> $OUTPUT_JSON

  echo "  {" >> $OUTPUT_STAGING_JSON
  echo "    \"name\": \"$NAME\"," >> $OUTPUT_STAGING_JSON
  echo "    \"url\": \"$STAGING_URL\"," >> $OUTPUT_STAGING_JSON
  echo "    \"hash\": \"$HASH\"," >> $OUTPUT_STAGING_JSON
  echo "    \"hash_raw\": \"$HASH_RAW\"," >> $OUTPUT_STAGING_JSON
  echo "    \"size\": $SIZE," >> $OUTPUT_STAGING_JSON
  echo "    \"sparse\": false," >> $OUTPUT_STAGING_JSON
  echo "    \"full_check\": true," >> $OUTPUT_STAGING_JSON
  echo "    \"has_ab\": true" >> $OUTPUT_STAGING_JSON
  # echo "    \"casync_caibx\": \"$AGNOS_STAGING_UPDATE_URL/$NAME-$HASH.caibx\"," >> $OUTPUT_STAGING_JSON
  # echo "    \"casync_store\": \"$AGNOS_STAGING_UPDATE_URL/$NAME-$HASH\"" >> $OUTPUT_STAGING_JSON
  echo "  }," >> $OUTPUT_STAGING_JSON
}

cd $ROOT

echo "[" > $OUTPUT_JSON
echo "[" > $OUTPUT_STAGING_JSON

process_file "$OUTPUT_DIR/system.img"
process_file "$OUTPUT_DIR/boot.img"
process_file "$FIRMWARE_DIR/abl.bin"
process_file "$FIRMWARE_DIR/xbl.bin"
process_file "$FIRMWARE_DIR/xbl_config.bin"
process_file "$FIRMWARE_DIR/devcfg.bin"
process_file "$FIRMWARE_DIR/aop.bin"

# remove trailing comma
sed -i '$ s/.$//' $OUTPUT_JSON
sed -i '$ s/.$//' $OUTPUT_STAGING_JSON

echo "]" >> $OUTPUT_JSON
echo "]" >> $OUTPUT_STAGING_JSON

echo "Done!"
