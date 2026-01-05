#!/usr/bin/env bash
# Flash system.img over USB network (usb0) - streaming directly to flash
# Designed for speed: sparse→raw→lz4→ssh→lz4 -d→dd
#
# Usage: ./flash_system_usb.sh [options]
#   SLOT=b ./flash_system_usb.sh    # flash to slot b
#   DEVICE_IP=x.x.x.x ./...         # use different IP
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
cd "$DIR"

# Configuration
DEVICE_IP="${DEVICE_IP:-192.168.7.1}"
DEVICE_USER="${DEVICE_USER:-comma}"
SLOT="${SLOT:-a}"
SYSTEM_IMG="$DIR/output/system.img"
RAW_IMG="$DIR/output/system.raw"
# Use partlabel - more reliable than /dev/sdXN which can change
PARTITION="/dev/disk/by-partlabel/system_$SLOT"

# Cleanup handler
cleanup() {
    # Don't delete raw image - it's useful for subsequent flashes
    :
}
trap cleanup EXIT

# Check dependencies
for cmd in simg2img lz4 ssh; do
    if ! command -v $cmd &>/dev/null; then
        echo "ERROR: $cmd not found. Install it first."
        [[ "$cmd" == "simg2img" ]] && echo "  apt install android-sdk-libsparse-utils  OR  brew install android-platform-tools"
        [[ "$cmd" == "lz4" ]] && echo "  apt install lz4  OR  brew install lz4"
        exit 1
    fi
done

# pv is optional but nice
HAS_PV=false
command -v pv &>/dev/null && HAS_PV=true

# Check input exists
if [[ ! -f "$SYSTEM_IMG" ]]; then
    echo "ERROR: $SYSTEM_IMG not found"
    exit 1
fi

# Get sparse image info
echo "==> Analyzing sparse image..."
SPARSE_SIZE=$(stat -c%s "$SYSTEM_IMG" 2>/dev/null || stat -f%z "$SYSTEM_IMG")
# Parse "Total of NNNN 4096-byte output blocks" from file output
RAW_BLOCKS=$(file "$SYSTEM_IMG" | grep -oP 'Total of \K\d+' || echo "0")
RAW_SIZE=$((RAW_BLOCKS * 4096))

echo "    Sparse size: $(numfmt --to=iec $SPARSE_SIZE 2>/dev/null || echo "$SPARSE_SIZE bytes")"
echo "    Raw size:    $(numfmt --to=iec $RAW_SIZE 2>/dev/null || echo "$RAW_SIZE bytes")"

# Convert sparse to raw if needed (or if sparse is newer)
if [[ ! -f "$RAW_IMG" ]] || [[ "$SYSTEM_IMG" -nt "$RAW_IMG" ]]; then
    echo "==> Converting sparse to raw..."
    echo "    (this takes ~30s, but only needed once per build)"
    CONVERT_START=$(date +%s)
    simg2img "$SYSTEM_IMG" "$RAW_IMG"
    CONVERT_END=$(date +%s)
    echo "    Done in $((CONVERT_END - CONVERT_START))s"
else
    echo "==> Using cached raw image (newer than sparse)"
fi

# Check device connectivity
echo "==> Checking device at $DEVICE_IP..."
if ! ping -c1 -W2 "$DEVICE_IP" &>/dev/null; then
    echo "ERROR: Device not reachable at $DEVICE_IP"
    echo "       Make sure USB is connected and usb0 is up"
    exit 1
fi

# Check SSH connectivity and device tools
echo "==> Checking device has required tools..."
if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$DEVICE_USER@$DEVICE_IP" "command -v lz4 && test -e $PARTITION" &>/dev/null; then
    echo "ERROR: Cannot SSH to device or missing lz4/partition"
    echo "       Trying to diagnose..."
    ssh -o ConnectTimeout=5 "$DEVICE_USER@$DEVICE_IP" "which lz4 || echo 'lz4 not found'; ls -la $PARTITION 2>&1 || echo 'partition not found'" || true
    exit 1
fi

# Prepare device
echo "==> Preparing device..."
ssh "$DEVICE_USER@$DEVICE_IP" "sudo true" || { echo "ERROR: sudo not working"; exit 1; }

echo ""
echo "=========================================="
echo "  FLASHING system_$SLOT"
echo "  $RAW_IMG"
echo "  → $DEVICE_IP:$PARTITION"
echo "=========================================="
echo ""
echo "Press Ctrl+C within 3 seconds to abort..."
sleep 3

# The pipeline:
# 1. Read raw image
# 2. lz4 compresses (~2:1 ratio, very fast)
# 3. pv shows progress (optional)
# 4. ssh streams to device, no compression (we use lz4)
# 5. lz4 -d decompresses on device
# 6. dd writes directly to partition with large block size

START_TIME=$(date +%s)

if $HAS_PV; then
    lz4 -1 -c "$RAW_IMG" | \
        pv -s "$RAW_SIZE" -N "Streaming" | \
        ssh -o Compression=no \
            -o TCPKeepAlive=yes \
            -o ServerAliveInterval=10 \
            "$DEVICE_USER@$DEVICE_IP" \
            "sudo lz4 -d -c | sudo dd of=$PARTITION bs=4M iflag=fullblock oflag=direct status=none"
else
    echo "(install pv for progress bar)"
    lz4 -1 -c "$RAW_IMG" | \
        ssh -o Compression=no \
            -o TCPKeepAlive=yes \
            -o ServerAliveInterval=10 \
            "$DEVICE_USER@$DEVICE_IP" \
            "sudo lz4 -d -c | sudo dd of=$PARTITION bs=4M iflag=fullblock oflag=direct status=none"
fi

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

echo ""
echo "==> Verifying write..."
# Quick sanity check - read ext4 magic at offset 0x438 (1080 bytes)
# ext4 magic is 0x53EF at little-endian offset 1080
MAGIC=$(ssh "$DEVICE_USER@$DEVICE_IP" "sudo dd if=$PARTITION bs=1 skip=1080 count=2 2>/dev/null | od -A n -t x1 | tr -d ' '")
if [[ "$MAGIC" == "53ef" ]]; then
    echo "    ✓ ext4 superblock magic found"
else
    echo "    ⚠ Warning: Expected ext4 magic '53ef', got '$MAGIC'"
fi

echo ""
echo "=========================================="
echo "  Done! Flashed system_$SLOT in ${ELAPSED}s"
echo "  Raw size: $(numfmt --to=iec $RAW_SIZE 2>/dev/null || echo "$RAW_SIZE bytes")"
if [[ $ELAPSED -gt 0 ]]; then
    SPEED=$(echo "scale=1; $RAW_SIZE / $ELAPSED / 1048576" | bc)
    echo "  Speed: ${SPEED} MB/s"
fi
echo "=========================================="
echo ""
echo "To reboot: ssh $DEVICE_USER@$DEVICE_IP 'sudo reboot'"
