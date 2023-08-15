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
  local NAME=$2
  local SPARSE=${3:-false}
  local FULL_CHECK=${4:-true}
  local HAS_AB=${5:-true}

  echo "Hashing $NAME..."
  local HASH=$(sha256sum $FILE | cut -c 1-64)
  local SIZE=$(wc -c < $FILE)
  echo "  $HASH ($SIZE bytes)"

  local HASH_RAW=$HASH
  if [ "$NAME" == "system" ]; then
    echo "Converting system to raw..."
    local FILE_RAW=/tmp/system.img.raw
    simg2img $FILE $FILE_RAW

    echo "Hashing system raw..."
    HASH_RAW=$(sha256sum $FILE_RAW | cut -c 1-64)
    SIZE=$(wc -c < $FILE_RAW)
    echo "  $HASH_RAW ($SIZE bytes) (raw)"


    # echo "Creating system casync files"
    # casync make --compression=xz --store $OTA_OUTPUT_DIR/system-$HASH_RAW $OTA_OUTPUT_DIR/system-$HASH_RAW.caibx $FILE_RAW

    rm $FILE_RAW
  fi

  echo "Compressing $NAME..."
  local FILENAME=$NAME-$HASH_RAW.img.xz
  local ARCHIVE=$OTA_OUTPUT_DIR/$FILENAME
  xz -vc $FILE > $ARCHIVE

  cat <<EOF | tee $OUTPUT_JSON $OUTPUT_STAGING_JSON > /dev/null
  {
    "name": "$NAME",
    "hash": "$HASH",
    "hash_raw": "$HASH_RAW",
    "size": $SIZE,
    "sparse": $SPARSE,
    "full_check": $FULL_CHECK,
    "has_ab": $HAS_AB,
EOF

  cat <<EOF >> $OUTPUT_JSON
    "url": "$AGNOS_UPDATE_URL/$FILENAME"
EOF
  cat <<EOF >> $OUTPUT_STAGING_JSON
    "url": "$AGNOS_STAGING_UPDATE_URL/$FILENAME"
EOF

#   if [ $NAME == "system" ]; then
#     cat <<EOF >> $OUTPUT_JSON
#     "casync_caibx": "$AGNOS_UPDATE_URL/$NAME-$HASH_RAW.caibx",
#     "casync_store": "$AGNOS_UPDATE_URL/$NAME-$HASH_RAW"
# EOF
#     cat <<EOF >> $OUTPUT_STAGING_JSON
#     "casync_caibx": "$AGNOS_STAGING_UPDATE_URL/$NAME-$HASH_RAW.caibx",
#     "casync_store": "$AGNOS_STAGING_UPDATE_URL/$NAME-$HASH_RAW"
# EOF
#   fi

  cat <<EOF | tee -a $OUTPUT_JSON $OUTPUT_STAGING_JSON > /dev/null
  },
EOF
}

cd $ROOT

echo "[" > $OUTPUT_JSON
echo "[" > $OUTPUT_STAGING_JSON

process_file "$OUTPUT_DIR/boot.img" boot
process_file "$FIRMWARE_DIR/abl.bin" abl
process_file "$FIRMWARE_DIR/xbl.bin" xbl
process_file "$FIRMWARE_DIR/xbl_config.bin" xbl_config
process_file "$FIRMWARE_DIR/devcfg.bin" devcfg
process_file "$FIRMWARE_DIR/aop.bin" aop
process_file "$OUTPUT_DIR/system.img" system true false true

# remove trailing comma
sed -i "$ s/.$//" $OUTPUT_JSON $OUTPUT_STAGING_JSON

echo "]" >> $OUTPUT_JSON
echo "]" >> $OUTPUT_STAGING_JSON

echo "Done!"
