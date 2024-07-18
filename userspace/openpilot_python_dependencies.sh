#!/bin/bash -e

echo "Installing python for openpilot"

# Install pyenv
export PYENV_ROOT="/usr/local/pyenv"
curl https://pyenv.run | bash
export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init -)"

PYTHON_VERSION="3.11.4"
if [ "$(uname -p)" == "aarch64" ]; then
  pyenv install --verbose $PYTHON_VERSION
else
  MAKEFLAGS="-j1" MAKE_OPTS="-j1" taskset --cpu-list 0 pyenv install --verbose $PYTHON_VERSION
fi

echo "Setting global python version"
pyenv global $PYTHON_VERSION

pip3 install --no-cache-dir --upgrade pip uv
