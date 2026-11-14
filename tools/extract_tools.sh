#!/usr/bin/env bash
set -e

git lfs &> /dev/null || {
  echo "ERROR: git lfs not installed"
  exit 1
}

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# grep for `-`, which stands for LFS pointer
if git lfs ls-files | awk '{print $2}' | grep -q -- "-"; then
  echo "Pulling git lfs objects..."
  git lfs install
  git lfs pull
fi
