#!/usr/bin/bash
set -ex

# for fast arm64 builds: https://namespace.so/docs/features/faster-builds

# install
# curl -fsSL https://get.namespace.so/cloud/install.sh | sh

nsc version update

nsc docker buildx cleanup
nsc docker buildx setup --use
