#!/bin/bash

# This script applies a patch from a Github URL (commit/PR) to the current path.
# Usage: ./apply_github_patch.sh <github_url>

URL=$1
if [ -z "$URL" ]; then
  echo "Usage: $0 <github_url>"
  exit 1
fi

# Download the diff file from the URL
DIFF_FILE=$(mktemp)
curl -sL "$URL.diff" > "$DIFF_FILE"
if [ $? -ne 0 ]; then
  echo "Failed to download diff from $URL"
  exit 1
fi

# Apply the patch
git apply "$DIFF_FILE"
if [ $? -ne 0 ]; then
  echo "Failed to apply patch from $URL"
  rm "$DIFF_FILE"
  exit 1
fi

echo "Successfully applied patch from $URL"
rm "$DIFF_FILE"
