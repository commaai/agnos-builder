#!/bin/bash
# Initialize git tracking of rootfs for live development
set -e

echo "Remounting root filesystem as read-write..."
mount -o remount,rw /

cd /
echo "Initializing git repository..."
git init

cat > .gitignore << 'EOF'
# Virtual filesystems
/proc/
/sys/
/dev/
/run/

# Tmpfs mounts
/tmp/
/var/
/rwtmp/

# User data partition
/data/

# Home overlay
/home/

# Git directory
/.git/

# Large directories to skip
/usr/local/venv/
/usr/local/uv/

# Cache files
*.pyc
__pycache__/
*.cache
.cache/
EOF

echo "Adding all files to git (this may take a minute)..."
git add -A

echo "Creating initial commit..."
git commit -m "initial rootfs state"

echo ""
echo "=== Rootfs git tracking initialized ==="
echo "Use 'cd / && git status' to see changes"
echo "Use 'cd / && git diff' to see diffs"
