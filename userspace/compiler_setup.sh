#!/bin/bash -e

export DEBIAN_FRONTEND=noninteractive

# Install apt-fast
apt-get update
apt-get install -yq curl sudo wget
bash -c "$(curl -sL https://git.io/vokNn)"

apt-fast install --no-install-recommends -yq build-essential ca-certificates checkinstall git qt5-default wget
