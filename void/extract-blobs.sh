#!/bin/bash
# Extract and clean agnos-*.deb blobs for Void Linux
# Removes: systemd units, armhf libs, weston/wayland (display stack)
# Keeps: firmware, aarch64 libs, binaries, udev rules, init scripts

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEBS_DIR="$SCRIPT_DIR/../userspace/debs"
BLOBS_DIR="$SCRIPT_DIR/blobs"
TMP_DIR="/tmp/agnos-blob-extract"

rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"

rm -rf "$BLOBS_DIR"
mkdir -p "$BLOBS_DIR"

echo "=== Extracting agnos-base.deb ==="
mkdir -p "$TMP_DIR/base"
dpkg-deb -R "$DEBS_DIR/agnos-base.deb" "$TMP_DIR/base"

# Remove systemd
rm -rf "$TMP_DIR/base/etc/systemd"
rm -rf "$TMP_DIR/base/lib/systemd"

# Remove armhf libs
rm -rf "$TMP_DIR/base/usr/lib/arm-linux-gnueabihf"

# Remove DEBIAN metadata
rm -rf "$TMP_DIR/base/DEBIAN"

# Move libs from aarch64-linux-gnu to just lib (Void convention)
if [ -d "$TMP_DIR/base/usr/lib/aarch64-linux-gnu" ]; then
    mv "$TMP_DIR/base/usr/lib/aarch64-linux-gnu"/* "$TMP_DIR/base/usr/lib/" 2>/dev/null || true
    rm -rf "$TMP_DIR/base/usr/lib/aarch64-linux-gnu"
fi

echo "=== Extracting agnos-wlan.deb ==="
mkdir -p "$TMP_DIR/wlan"
dpkg-deb -R "$DEBS_DIR/agnos-wlan_0.0.3.deb" "$TMP_DIR/wlan"

# Remove systemd
rm -rf "$TMP_DIR/wlan/etc/systemd"
rm -rf "$TMP_DIR/wlan/lib/systemd"

# Remove old sysvinit rc*.d symlinks
rm -rf "$TMP_DIR/wlan/etc/rc2.d"
rm -rf "$TMP_DIR/wlan/etc/rc3.d"
rm -rf "$TMP_DIR/wlan/etc/rc4.d"
rm -rf "$TMP_DIR/wlan/etc/rc5.d"

# Remove DEBIAN metadata
rm -rf "$TMP_DIR/wlan/DEBIAN"

# Move libs from aarch64-linux-gnu to just lib
if [ -d "$TMP_DIR/wlan/usr/lib/aarch64-linux-gnu" ]; then
    mv "$TMP_DIR/wlan/usr/lib/aarch64-linux-gnu"/* "$TMP_DIR/wlan/usr/lib/" 2>/dev/null || true
    rm -rf "$TMP_DIR/wlan/usr/lib/aarch64-linux-gnu"
fi

echo "=== Extracting agnos-display.deb (GPU/OpenCL only) ==="
mkdir -p "$TMP_DIR/display"
dpkg-deb -R "$DEBS_DIR/agnos-display_0.0.1.deb" "$TMP_DIR/display"

# Remove weston entirely - not used
rm -rf "$TMP_DIR/display/usr/bin/weston"*
rm -rf "$TMP_DIR/display/usr/bin/wcap-decode"
rm -rf "$TMP_DIR/display/usr/libexec/weston"*
rm -rf "$TMP_DIR/display/usr/share/weston"
rm -rf "$TMP_DIR/display/usr/share/wayland-sessions"
rm -rf "$TMP_DIR/display/usr/lib/*/weston"
rm -rf "$TMP_DIR/display/usr/lib/*/libweston"*
rm -rf "$TMP_DIR/display/usr/lib/*/pkgconfig/weston"*

# Remove wayland libs (not needed without weston)
rm -f "$TMP_DIR/display/usr/lib/*/libwayland"*
rm -f "$TMP_DIR/display/usr/lib/libwayland"*
rm -f "$TMP_DIR/display/usr/lib/*/libeglSubDriverWayland"*
rm -f "$TMP_DIR/display/usr/lib/libeglSubDriverWayland"*

# Remove armhf libs
rm -rf "$TMP_DIR/display/usr/lib/arm-linux-gnueabihf"

# Remove DEBIAN metadata
rm -rf "$TMP_DIR/display/DEBIAN"

# Move libs from aarch64-linux-gnu to just lib
if [ -d "$TMP_DIR/display/usr/lib/aarch64-linux-gnu" ]; then
    mkdir -p "$TMP_DIR/display/usr/lib"
    mv "$TMP_DIR/display/usr/lib/aarch64-linux-gnu"/* "$TMP_DIR/display/usr/lib/" 2>/dev/null || true
    rm -rf "$TMP_DIR/display/usr/lib/aarch64-linux-gnu"
fi

# Void Linux uses unified /usr layout:
# /bin -> /usr/bin, /sbin -> /usr/bin, /lib -> /usr/lib, /lib64 -> /usr/lib
# Move everything to /usr/* to avoid conflicts with symlinks

for pkg in base wlan display; do
    # /lib/firmware -> /usr/lib/firmware
    if [ -d "$TMP_DIR/$pkg/lib/firmware" ]; then
        mkdir -p "$TMP_DIR/$pkg/usr/lib/firmware"
        cp -a "$TMP_DIR/$pkg/lib/firmware"/* "$TMP_DIR/$pkg/usr/lib/firmware/" 2>/dev/null || true
    fi
    rm -rf "$TMP_DIR/$pkg/lib" 2>/dev/null || true
    
    # /lib64 -> /usr/lib
    if [ -d "$TMP_DIR/$pkg/lib64" ]; then
        mkdir -p "$TMP_DIR/$pkg/usr/lib"
        cp -a "$TMP_DIR/$pkg/lib64"/* "$TMP_DIR/$pkg/usr/lib/" 2>/dev/null || true
        rm -rf "$TMP_DIR/$pkg/lib64"
    fi
    
    # /sbin -> /usr/bin
    if [ -d "$TMP_DIR/$pkg/sbin" ]; then
        mkdir -p "$TMP_DIR/$pkg/usr/bin"
        cp -a "$TMP_DIR/$pkg/sbin"/* "$TMP_DIR/$pkg/usr/bin/" 2>/dev/null || true
        rm -rf "$TMP_DIR/$pkg/sbin"
    fi
    
    # /bin -> /usr/bin (if any)
    if [ -d "$TMP_DIR/$pkg/bin" ]; then
        mkdir -p "$TMP_DIR/$pkg/usr/bin"
        cp -a "$TMP_DIR/$pkg/bin"/* "$TMP_DIR/$pkg/usr/bin/" 2>/dev/null || true
        rm -rf "$TMP_DIR/$pkg/bin"
    fi
    
    # /usr/sbin -> /usr/bin (Void has no /usr/sbin)
    if [ -d "$TMP_DIR/$pkg/usr/sbin" ]; then
        mkdir -p "$TMP_DIR/$pkg/usr/bin"
        cp -a "$TMP_DIR/$pkg/usr/sbin"/* "$TMP_DIR/$pkg/usr/bin/" 2>/dev/null || true
        rm -rf "$TMP_DIR/$pkg/usr/sbin"
    fi
    
    # Remove any /usr/lib64 dirs (usually just broken symlinks)
    rm -rf "$TMP_DIR/$pkg/usr/lib64" 2>/dev/null || true
    
    # Remove ld-linux symlink that creates a loop with Void's /lib -> /usr/lib
    rm -f "$TMP_DIR/$pkg/usr/lib/ld-linux-aarch64.so.1" 2>/dev/null || true
    
    # Remove wayland libs 
    rm -f "$TMP_DIR/$pkg/usr/lib/libwayland"* 2>/dev/null || true
done

# Clean up empty dirs
find "$TMP_DIR" -type d -empty -delete 2>/dev/null || true

echo "=== Copying to blobs directory ==="
cp -a "$TMP_DIR/base" "$BLOBS_DIR/"
cp -a "$TMP_DIR/wlan" "$BLOBS_DIR/"
cp -a "$TMP_DIR/display" "$BLOBS_DIR/"

echo "=== Summary ==="
echo "Base:"
du -sh "$BLOBS_DIR/base"
find "$BLOBS_DIR/base" -type f | wc -l
echo

echo "WLAN:"
du -sh "$BLOBS_DIR/wlan"
find "$BLOBS_DIR/wlan" -type f | wc -l
echo

echo "Display (GPU/OpenCL):"
du -sh "$BLOBS_DIR/display"
find "$BLOBS_DIR/display" -type f | wc -l
echo

echo "Total:"
du -sh "$BLOBS_DIR"

echo
echo "Done! Blobs extracted to $BLOBS_DIR"
