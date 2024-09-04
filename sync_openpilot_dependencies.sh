#!/usr/bin/env bash
set -e

# Make sure we're in the correct spot
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
cd $DIR

cd userspace/uv
curl -sSo openpilot/pyproject.toml https://raw.githubusercontent.com/commaai/openpilot/master/pyproject.toml

export PYOPENCL_CL_PRETEND_VERSION="2.0" && \
pc="$(python -c "import sysconfig;print(sysconfig.get_config_vars('installed_base')[0])")" && \
pcpath=$pc"/lib/pkgconfig" && \
export PKG_CONFIG_PATH="$pcpath:$PKG_CONFIG_PATH" && \
uv lock --upgrade
