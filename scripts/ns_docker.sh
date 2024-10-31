#!/usr/bin/bash
set -e

# for fast arm64 builds: https://namespace.so/docs/features/faster-builds

if ! command -v nsc &> /dev/null; then
  echo "nsc missing, install with"
  echo ""
  echo "curl -fsSL https://get.namespace.so/cloud/install.sh | sh"
  exit 1
fi

nsc version update

nsc docker buildx cleanup
nsc docker buildx setup --use
