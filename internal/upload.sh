FOUND=0
if [ "$1" == "production" ]; then
  OTA_JSON="$OTA_DIR/ota.json"
  EXTRA_JSON="$OTA_DIR/extra.json"
  DATA_CONTAINER="agnosupdate"
  FOUND=1
fi
if [ "$1" == "staging" ]; then
  OTA_JSON="$OTA_DIR/ota-staging.json"
  EXTRA_JSON="$OTA_DIR/extra-staging.json"
  DATA_CONTAINER="agnosupdate-staging"
  FOUND=1
fi

if [ $FOUND == 0 ]; then
  echo "Supply either 'production' or 'staging' as first argument!"
  exit 1
fi
