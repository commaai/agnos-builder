#!/bin/bash -e

export XDG_DATA_HOME="/usr/local"
source /usr/local/venv/bin/activate 

# Build PyQt5 wheel
cd /tmp
wget https://files.pythonhosted.org/packages/5c/46/b4b6eae1e24d9432905ef1d4e7c28b6610e28252527cdc38f2a75997d8b5/PyQt5-5.15.9.tar.gz
tar xf PyQt5-5.15.9.tar.gz
cd PyQt5-5.15.9

export MAKEFLAGS="-j$(nproc)"
pip wheel -w . --verbose --config-settings --confirm-license= .
