#!/bin/bash
# Show changes since initial commit
cd /

if [ ! -d .git ]; then
    echo "Error: Git not initialized. Run rootfs-init.sh first."
    exit 1
fi

echo "=== Git Status ==="
git status --short

echo ""
echo "=== Modified Files ==="
git diff --name-only

echo ""
echo "=== Untracked Files ==="
git ls-files --others --exclude-standard

echo ""
echo "=== Summary ==="
MODIFIED=$(git diff --name-only | wc -l)
UNTRACKED=$(git ls-files --others --exclude-standard | wc -l)
echo "Modified:  $MODIFIED files"
echo "Untracked: $UNTRACKED files"

echo ""
echo "Commands:"
echo "  cd / && git diff              # Full diff"
echo "  cd / && git diff <file>       # Specific file"
echo "  cd / && git checkout <file>   # Revert file"
