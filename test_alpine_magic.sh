#!/usr/bin/env bash
set -euo pipefail

IMAGE_PATH="${1:-output/alpine/system-alpine.img}"

if [ ! -f "$IMAGE_PATH" ]; then
  echo "Missing $IMAGE_PATH"
  echo "Build it first with ./build_alpine.sh"
  exit 1
fi

cat <<EOF
Alpine splash image ready at: $IMAGE_PATH

Manual smoke test until automation exists:
  1. Flash the image to a spare comma 3/3X or boot it in your preferred ARM64 VM.
  2. Let the device boot normally. OpenRC should launch /usr/comma/magic.py automatically.
  3. Verify the comma logo (bg.jpg) appears and the backlight turns on.
  4. If it does not, capture /var/log/magic.log from the device and file an issue.
EOF
