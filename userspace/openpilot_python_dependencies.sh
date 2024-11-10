#!/bin/bash -e

echo "installing uv..."

export XDG_DATA_HOME="/usr/local"
UV_BIN="$HOME/.local/bin"
PATH="$UV_BIN:$PATH"

curl -LsSf https://astral.sh/uv/install.sh | sh

# Create and activate virtual environment with specific Python version
PYTHON_VERSION="3.12"
uv venv $XDG_DATA_HOME/venv --seed --python-preference only-managed --python=$PYTHON_VERSION

# Ensure the virtual environment is activated
. $XDG_DATA_HOME/venv/bin/activate

# Verify Python version and create pkg-config directory if needed
python_path=$(python -c "import sys; print(sys.prefix)")
mkdir -p "${python_path}/lib/pkgconfig"

# Create the necessary pkg-config files
cat > "${python_path}/lib/pkgconfig/python-${PYTHON_VERSION}.pc" << EOF
prefix=${python_path}
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: Python
Description: Python library
Version: ${PYTHON_VERSION}
Libs: -L\${libdir} -lpython${PYTHON_VERSION}
Cflags: -I\${includedir}/python${PYTHON_VERSION}
EOF

# Create embed version as well
cp "${python_path}/lib/pkgconfig/python-${PYTHON_VERSION}.pc" "${python_path}/lib/pkgconfig/python-${PYTHON_VERSION}-embed.pc"
