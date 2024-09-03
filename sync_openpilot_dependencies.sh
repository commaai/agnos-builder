#!/usr/bin/env bash
set -e

# Make sure we're in the correct spot
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
cd $DIR

cd userspace/uv
curl -sSo openpilot/pyproject.toml https://raw.githubusercontent.com/commaai/openpilot/master/pyproject.toml
curl -sSo openpilot/uv.lock https://raw.githubusercontent.com/commaai/openpilot/master/uv.lock
uv lock
