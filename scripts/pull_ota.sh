#!/usr/bin/env bash
set -e

# Make sure we're in the correct directory
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"

# Constants
OUTPUT_DIR="$DIR/../output"

if [ "$1" == "" ]; then
  echo "Supply the URL to the OTA JSON as first argument!"
  exit 1
fi

OTA_JSON=$(mktemp)
wget $1 -O $OTA_JSON

mkdir -p $OUTPUT_DIR
cd $OUTPUT_DIR

download_image() {
  local name=$1

  local url=$(cat $OTA_JSON | jq -r ".[] | select(.name == \"$name\") | .url")
  if [ "$url" == "null" ]; then
    return
  fi

  local hash_raw=$(cat $OTA_JSON | jq -r ".[] | select(.name == \"$name\") | .hash_raw")
  local file_name=$(basename $url .xz)
  file_name=${file_name//-$hash_raw/}

  echo "Downloading $file_name..."
  curl $url | xz -d > $file_name
}

for name in boot system; do
  download_image $name
done

echo "Done!"
