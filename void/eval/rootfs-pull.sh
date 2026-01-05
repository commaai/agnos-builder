#!/bin/bash
# Pull rootfs changes from device to host
set -e

DEVICE="${1:-192.168.7.1}"
USER="${2:-comma}"

echo "Connecting to $USER@$DEVICE..."

# Find most recent export
LATEST=$(ssh "$USER@$DEVICE" "ls -dt /data/rootfs-export-* 2>/dev/null | head -1" || true)

if [ -z "$LATEST" ]; then
    echo "No exports found on device."
    echo "Run 'rootfs-export.sh' on the device first."
    exit 1
fi

DEST="./void/device-changes/$(basename "$LATEST")"
mkdir -p "$DEST"

echo "Pulling $LATEST..."
scp -r "$USER@$DEVICE:$LATEST/*" "$DEST/"

echo ""
echo "=== Pulled to $DEST ==="
ls -la "$DEST"

echo ""
echo "Review commands:"
echo "  cat $DEST/modified.patch           # See changes to existing files"
echo "  cat $DEST/modified-files.txt       # List modified files"
echo "  cat $DEST/new-files.txt            # List new files"
echo "  ls -la $DEST/new-files/            # Browse new files"
echo ""
echo "To diff against Ubuntu manifest:"
echo "  diff -u void/manifests/ubuntu-manifest.txt $DEST/current-manifest.txt | less"
