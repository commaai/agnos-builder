#!/bin/bash -e

echo "installing uv..."

export XDG_DATA_HOME="/usr/local"

curl -LsSf https://astral.sh/uv/install.sh | sh

PYTHON_VERSION="3.12"

# uv requires virtual env either managed or system before installing dependencies
uv venv $XDG_DATA_HOME/venv --seed --python-preference only-managed --python=$PYTHON_VERSION
