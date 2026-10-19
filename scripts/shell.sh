#!/usr/bin/env bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null && pwd)"

docker buildx build --load --target agnos -t agnos-builder -f $DIR/Dockerfile.agnos $DIR \
  --build-arg UBUNTU_BASE_IMAGE=ubuntu-base-24.04.3-base-arm64.tar.gz --platform=linux/arm64
docker run -it --rm agnos-builder:latest /bin/bash
