#!/bin/bash -e

# Use pyenv venv
export PATH="/usr/local/pyenv/bin:/usr/local/pyenv/shims:$PATH"
export PYENV_ROOT="/usr/local/pyenv"
eval "$(pyenv init -)"
eval "$(pyenv virtualenv-init -)"

# Build PyQt5 wheel
cd /tmp
wget https://files.pythonhosted.org/packages/5c/46/b4b6eae1e24d9432905ef1d4e7c28b6610e28252527cdc38f2a75997d8b5/PyQt5-5.15.9.tar.gz
tar xf PyQt5-5.15.9.tar.gz
cd PyQt5-5.15.9

export MAKEFLAGS="-j$(nproc)"
pip wheel -w . --verbose --config-settings --confirm-license= .
