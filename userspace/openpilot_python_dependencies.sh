#!/bin/bash -e

echo "installing uv..."

export XDG_DATA_HOME="/usr/local"
export CARGO_HOME="$XDG_DATA_HOME/.cargo"

curl -LsSf https://astral.sh/uv/install.sh | sh
eval ". $CARGO_HOME/env"

PYTHON_VERSION="3.12.3"

# uv requires virtual env either managed or system before installing dependencies
uv venv $XDG_DATA_HOME/venv --seed --python-preference only-managed --python=$PYTHON_VERSION
