#!/bin/bash
# Export changes for backporting to Docker build
set -e

cd /

if [ ! -d .git ]; then
    echo "Error: Git not initialized. Run rootfs-init.sh first."
    exit 1
fi

EXPORT_DIR="/data/rootfs-export-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$EXPORT_DIR"

echo "Exporting changes to $EXPORT_DIR..."

# Export diff as patch
git diff > "$EXPORT_DIR/modified.patch"

# List of modified files
git diff --name-only > "$EXPORT_DIR/modified-files.txt"

# List of new/untracked files
git ls-files --others --exclude-standard > "$EXPORT_DIR/new-files.txt"

# Copy new files preserving directory structure
mkdir -p "$EXPORT_DIR/new-files"
while IFS= read -r f; do
    if [ -e "/$f" ]; then
        mkdir -p "$EXPORT_DIR/new-files/$(dirname "$f")"
        cp -a "/$f" "$EXPORT_DIR/new-files/$f"
    fi
done < "$EXPORT_DIR/new-files.txt"

# Generate current manifest
rootfs-manifest.sh "$EXPORT_DIR/current-manifest.txt"

echo ""
echo "=== Export Complete ==="
echo "Location: $EXPORT_DIR"
echo ""
echo "Contents:"
ls -la "$EXPORT_DIR"
echo ""
echo "Modified files: $(wc -l < "$EXPORT_DIR/modified-files.txt")"
echo "New files:      $(wc -l < "$EXPORT_DIR/new-files.txt")"
echo ""
echo "Retrieve with:"
echo "  scp -r comma@192.168.7.1:$EXPORT_DIR ."
