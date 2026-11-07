#!/bin/bash -e
# Void ships Python 3.14 only; openpilot pins >=3.12.3,<3.13.
# Use a uv-managed (python-build-standalone) 3.12 for the venv.
export XDG_DATA_HOME="/usr/local"
export UV_PYTHON_INSTALL_DIR="/usr/local/uv/python"
uv python install 3.12
uv venv $XDG_DATA_HOME/venv --seed --python-preference only-managed --python=3.12
