#!/bin/bash -e

echo "Installing python for openpilot"

echo "installing uv..."
curl -LsSf https://astral.sh/uv/install.sh | sh
UV_BIN='$HOME/.cargo/env'
ADD_PATH_CMD=". \"$UV_BIN\""
eval $ADD_PATH_CMD

PYTHON_VERSION="3.11.4"
if [ "$(uname -p)" == "aarch64" ]; then
  uv python install $PYTHON_VERSION
else
  MAKEFLAGS="-j1" MAKE_OPTS="-j1" taskset --cpu-list 0 uv python install --verbose $PYTHON_VERSION
fi

# uv requires virtual env either managed or system before installing dependencies
uv venv --python-preference only-system
# need to activate virtual env otherwise call to uv pip install throws error,
# error: No virtual or system environment found for path ...
source .venv/bin/activate
# install dependencies using system python 
uv pip install --python=$(which python) --no-cache-dir --upgrade pip
