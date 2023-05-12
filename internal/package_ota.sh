#!/bin/bash -e

# Make sure we're in the correct spot
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"

ROOT="$DIR/../"
TMP_DIR="/tmp/agnos-builder-tmp"
OUTPUT_DIR="$ROOT/output"
OTA_OUTPUT_DIR="$OUTPUT_DIR/ota"
FIRMWARE_DIR="$ROOT/agnos-firmware"

SYSTEM_IMAGE_RAW="/tmp/system.img.raw"
SYSTEM_IMAGE="$OUTPUT_DIR/system.img"
BOOT_IMAGE="$OUTPUT_DIR/boot.img"
ABL_IMAGE="$FIRMWARE_DIR/abl.bin"
XBL_IMAGE="$FIRMWARE_DIR/xbl.bin"
XBL_CONFIG_IMAGE="$FIRMWARE_DIR/xbl_config.bin"
DEVCFG_IMAGE="$FIRMWARE_DIR/devcfg.bin"
AOP_IMAGE="$FIRMWARE_DIR/aop.bin"

AGNOS_UPDATE_URL=${AGNOS_UPDATE_URL:-https://commadist.azureedge.net/agnosupdate}
AGNOS_STAGING_UPDATE_URL=${AGNOS_STAGING_UPDATE_URL:-https://commadist.azureedge.net/agnosupdate-staging}
OUTPUT_JSON="$OTA_OUTPUT_DIR/ota.json"
OUTPUT_STAGING_JSON="$OTA_OUTPUT_DIR/ota-staging.json"

cd $ROOT

# Create dirs if non-existent
mkdir -p $OTA_OUTPUT_DIR

# Make sure archive dir is empty
rm -rf $OTA_OUTPUT_DIR
mkdir -p $OTA_OUTPUT_DIR

# Hashing
echo "Hashing system..."
SPARSE_SYSTEM_HASH=$(sha256sum $SYSTEM_IMAGE | cut -c 1-64)
simg2img $SYSTEM_IMAGE $SYSTEM_IMAGE_RAW
SYSTEM_HASH=$(sha256sum $SYSTEM_IMAGE_RAW | cut -c 1-64)
SYSTEM_SIZE=$(wc -c < $SYSTEM_IMAGE_RAW)

echo "Hashing boot..."
BOOT_HASH=$(sha256sum $BOOT_IMAGE | cut -c 1-64)
BOOT_SIZE=$(wc -c < $BOOT_IMAGE)

echo "Hashing abl..."
ABL_HASH=$(sha256sum $ABL_IMAGE | cut -c 1-64)
ABL_SIZE=$(wc -c < $ABL_IMAGE)

echo "Hashing xbl..."
XBL_HASH=$(sha256sum $XBL_IMAGE | cut -c 1-64)
XBL_SIZE=$(wc -c < $XBL_IMAGE)

echo "Hashing xbl_config..."
XBL_CONFIG_HASH=$(sha256sum $XBL_CONFIG_IMAGE | cut -c 1-64)
XBL_CONFIG_SIZE=$(wc -c < $XBL_CONFIG_IMAGE)

echo "Hashing devcfg..."
DEVCFG_HASH=$(sha256sum $DEVCFG_IMAGE | cut -c 1-64)
DEVCFG_SIZE=$(wc -c < $DEVCFG_IMAGE)

echo "Hashing aop..."
AOP_HASH=$(sha256sum $AOP_IMAGE | cut -c 1-64)
AOP_SIZE=$(wc -c < $AOP_IMAGE)

# Compressing
SYSTEM_ARCHIVE=$OTA_OUTPUT_DIR/system-$SYSTEM_HASH.img.xz
BOOT_ARCHIVE=$OTA_OUTPUT_DIR/boot-$BOOT_HASH.img.xz
ABL_ARCHIVE=$OTA_OUTPUT_DIR/abl-$ABL_HASH.img.xz
XBL_ARCHIVE=$OTA_OUTPUT_DIR/xbl-$XBL_HASH.img.xz
XBL_CONFIG_ARCHIVE=$OTA_OUTPUT_DIR/xbl_config-$XBL_CONFIG_HASH.img.xz
DEVCFG_ARCHIVE=$OTA_OUTPUT_DIR/devcfg-$DEVCFG_HASH.img.xz
AOP_ARCHIVE=$OTA_OUTPUT_DIR/aop-$AOP_HASH.img.xz

echo "Compressing system..."
xz -vc $SYSTEM_IMAGE > $SYSTEM_ARCHIVE
echo "Compressing boot..."
xz -vc $BOOT_IMAGE > $BOOT_ARCHIVE
echo "Compressing abl..."
xz -vc $ABL_IMAGE > $ABL_ARCHIVE
echo "Compressing xbl..."
xz -vc $XBL_IMAGE > $XBL_ARCHIVE
echo "Compressing xbl_config..."
xz -vc $XBL_CONFIG_IMAGE > $XBL_CONFIG_ARCHIVE
echo "Compressing devcfg..."
xz -vc $DEVCFG_IMAGE > $DEVCFG_ARCHIVE
echo "Compressing aop..."
xz -vc $AOP_IMAGE > $AOP_ARCHIVE

#echo "Creating system casync files"
#casync make --compression=xz --store $OTA_OUTPUT_DIR/system-$SYSTEM_HASH $OTA_OUTPUT_DIR/system-$SYSTEM_HASH.caibx $SYSTEM_IMAGE_RAW

rm $SYSTEM_IMAGE_RAW

# Generating JSONs
echo "Generating production JSON ($OUTPUT_JSON)..."
tee $OUTPUT_JSON > /dev/null <<EOM
[
  {
    "name": "boot",
    "url": "$AGNOS_UPDATE_URL/boot-$BOOT_HASH.img.xz",
    "hash": "$BOOT_HASH",
    "hash_raw": "$BOOT_HASH",
    "size": $BOOT_SIZE,
    "sparse": false,
    "full_check": true,
    "has_ab": true
  },
  {
    "name": "abl",
    "url": "$AGNOS_UPDATE_URL/abl-$ABL_HASH.img.xz",
    "hash": "$ABL_HASH",
    "hash_raw": "$ABL_HASH",
    "size": $ABL_SIZE,
    "sparse": false,
    "full_check": true,
    "has_ab": true
  },
  {
    "name": "xbl",
    "url": "$AGNOS_UPDATE_URL/xbl-$XBL_HASH.img.xz",
    "hash": "$XBL_HASH",
    "hash_raw": "$XBL_HASH",
    "size": $XBL_SIZE,
    "sparse": false,
    "full_check": true,
    "has_ab": true
  },
  {
    "name": "xbl_config",
    "url": "$AGNOS_UPDATE_URL/xbl_config-$XBL_CONFIG_HASH.img.xz",
    "hash": "$XBL_CONFIG_HASH",
    "hash_raw": "$XBL_CONFIG_HASH",
    "size": $XBL_CONFIG_SIZE,
    "sparse": false,
    "full_check": true,
    "has_ab": true
  },
  {
    "name": "devcfg",
    "url": "$AGNOS_UPDATE_URL/devcfg-$DEVCFG_HASH.img.xz",
    "hash": "$DEVCFG_HASH",
    "hash_raw": "$DEVCFG_HASH",
    "size": $DEVCFG_SIZE,
    "sparse": false,
    "full_check": true,
    "has_ab": true
  },
  {
    "name": "aop",
    "url": "$AGNOS_UPDATE_URL/aop-$AOP_HASH.img.xz",
    "hash": "$AOP_HASH",
    "hash_raw": "$AOP_HASH",
    "size": $AOP_SIZE,
    "sparse": false,
    "full_check": true,
    "has_ab": true
  },
  {
    "name": "system",
    "url": "$AGNOS_UPDATE_URL/system-$SYSTEM_HASH.img.xz",
    "hash": "$SPARSE_SYSTEM_HASH",
    "hash_raw": "$SYSTEM_HASH",
    "size": $SYSTEM_SIZE,
    "sparse": true,
    "full_check": false,
    "has_ab": true
  }
]
EOM
#    "casync_caibx": "$AGNOS_UPDATE_URL/system-$SYSTEM_HASH.caibx",
#    "casync_store": "$AGNOS_UPDATE_URL/system-$SYSTEM_HASH"


echo "Generating staging JSON ($OUTPUT_STAGING_JSON)..."
tee $OUTPUT_STAGING_JSON > /dev/null <<EOM
[
  {
    "name": "boot",
    "url": "$AGNOS_STAGING_UPDATE_URL/boot-$BOOT_HASH.img.xz",
    "hash": "$BOOT_HASH",
    "hash_raw": "$BOOT_HASH",
    "size": $BOOT_SIZE,
    "sparse": false,
    "full_check": true,
    "has_ab": true
  },
  {
    "name": "abl",
    "url": "$AGNOS_STAGING_UPDATE_URL/abl-$ABL_HASH.img.xz",
    "hash": "$ABL_HASH",
    "hash_raw": "$ABL_HASH",
    "size": $ABL_SIZE,
    "sparse": false,
    "full_check": true,
    "has_ab": true
  },
  {
    "name": "xbl",
    "url": "$AGNOS_STAGING_UPDATE_URL/xbl-$XBL_HASH.img.xz",
    "hash": "$XBL_HASH",
    "hash_raw": "$XBL_HASH",
    "size": $XBL_SIZE,
    "sparse": false,
    "full_check": true,
    "has_ab": true
  },
  {
    "name": "xbl_config",
    "url": "$AGNOS_STAGING_UPDATE_URL/xbl_config-$XBL_CONFIG_HASH.img.xz",
    "hash": "$XBL_CONFIG_HASH",
    "hash_raw": "$XBL_CONFIG_HASH",
    "size": $XBL_CONFIG_SIZE,
    "sparse": false,
    "full_check": true,
    "has_ab": true
  },
  {
    "name": "devcfg",
    "url": "$AGNOS_STAGING_UPDATE_URL/devcfg-$DEVCFG_HASH.img.xz",
    "hash": "$DEVCFG_HASH",
    "hash_raw": "$DEVCFG_HASH",
    "size": $DEVCFG_SIZE,
    "sparse": false,
    "full_check": true,
    "has_ab": true
  },
  {
    "name": "aop",
    "url": "$AGNOS_STAGING_UPDATE_URL/aop-$AOP_HASH.img.xz",
    "hash": "$AOP_HASH",
    "hash_raw": "$AOP_HASH",
    "size": $AOP_SIZE,
    "sparse": false,
    "full_check": true,
    "has_ab": true
  },
  {
    "name": "system",
    "url": "$AGNOS_STAGING_UPDATE_URL/system-$SYSTEM_HASH.img.xz",
    "hash": "$SPARSE_SYSTEM_HASH",
    "hash_raw": "$SYSTEM_HASH",
    "size": $SYSTEM_SIZE,
    "sparse": true,
    "full_check": false,
    "has_ab": true
  }
]
EOM
#    "casync_caibx": "$AGNOS_STAGING_UPDATE_URL/system-$SYSTEM_HASH.caibx",
#    "casync_store": "$AGNOS_STAGING_UPDATE_URL/system-$SYSTEM_HASH"

echo
echo "Done!"
echo "  System hash: $SYSTEM_HASH"
echo "  Boot hash: $BOOT_HASH"
echo "  abl hash: $ABL_HASH"
echo "  xbl hash: $XBL_HASH"
echo "  xbl_config hash: $XBL_CONFIG_HASH"
echo "  devcfg hash: $DEVCFG_HASH"
echo "  aop hash: $AOP_HASH"