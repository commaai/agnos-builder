#!/bin/bash -e

export CARGO_HOME="$XDG_DATA_HOME/.cargo"

apt-fast update
apt-fast install -yq --no-install-recommends python3-dev

curl -LsSf https://astral.sh/uv/install.sh | sh
eval ". $CARGO_HOME/env"

uv venv $XDG_DATA_HOME/venv
