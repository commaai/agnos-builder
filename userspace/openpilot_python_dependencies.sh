#!/bin/bash -e
# install pyproject.toml dependencies
apt-get install portaudio19-dev -y
apt-get install opencl-headers -y
apt-get install gcc-arm-none-eabi -y

echo "installing uv..."

export XDG_DATA_HOME="/usr/local"
export CARGO_HOME="$XDG_DATA_HOME/.cargo"

curl -LsSf https://astral.sh/uv/install.sh | sh
eval ". $CARGO_HOME/env"

PYTHON_VERSION="3.11.4"

echo "Installing python for openpilot"

if [ "$(uname -p)" == "aarch64" ]; then
  uv python install $PYTHON_VERSION
else
  MAKEFLAGS="-j1" MAKE_OPTS="-j1" taskset --cpu-list 0 uv python install --verbose $PYTHON_VERSION
fi

# uv requires virtual env either managed or system before installing dependencies
uv venv $XDG_DATA_HOME/venv --seed --python-preference only-managed --python=$PYTHON_VERSION
