#!/bin/bash -e

echo "Installing python for openpilot"

if ! command -v "uv" > /dev/null 2>&1; then
  echo "installing uv..."
  curl -LsSf https://astral.sh/uv/install.sh | sh
  UV_BIN='$HOME/.cargo/env'
  ADD_PATH_CMD=". \"$UV_BIN\""
  eval $ADD_PATH_CMD
fi

PYTHON_VERSION="3.11.4"
if [ "$(uname -p)" == "aarch64" ]; then
  uv python install 3.11.4
else
  MAKEFLAGS="-j1" MAKE_OPTS="-j1" taskset --cpu-list 0 uv python install --verbose $PYTHON_VERSION
fi
uv venv
uv pip install --no-cache-dir --upgrade pip uv
