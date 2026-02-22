#!/bin/bash
# Generate complete file manifest with metadata
# Format: permissions owner:group type path [-> symlink_target]

OUTPUT="${1:-/data/manifest.txt}"

echo "Generating rootfs manifest..."

{
    echo "# Rootfs manifest - $(date -Iseconds)"
    echo "# Format: perms owner:group type path [-> symlink_target]"
    echo ""
    
    # Generate manifest for regular files and directories
    # -xdev stays on same filesystem (excludes /data, /proc, etc.)
    find / -xdev \
        -not -path '/.git/*' \
        \( -type f -o -type d -o -type l \) \
        -printf '%M %u:%g %y %p' \
        -printf ' -> %l' \
        -printf '\n' \
        2>/dev/null | sort -k4
    
    echo ""
    echo "# Installed packages:"
    if command -v xbps-query &>/dev/null; then
        xbps-query -l
    elif command -v dpkg &>/dev/null; then
        dpkg -l
    fi
} > "$OUTPUT"

LINES=$(wc -l < "$OUTPUT")
echo "Manifest written to $OUTPUT ($LINES lines)"
