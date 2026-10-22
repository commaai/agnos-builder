#!/bin/bash
set -euo pipefail

build=/tmp/raylib-build
output=/tmp/agnos/raylib
raylib_python_rev=649d19c33175fdb7800e3ccbe988f140e659cfce
raylib_rev=231c8eec359567ef0e5e9a8aeede8ac77659fdd5

git init "$build"
git -C "$build" remote add origin https://github.com/dorapilot/raylib-python-cffi.git
git -C "$build" fetch --depth=1 origin "$raylib_python_rev"
git -C "$build" checkout --detach FETCH_HEAD
git -C "$build" submodule update --init --depth=1 raylib-c raygui
test "$(git -C "$build/raylib-c" rev-parse HEAD)" = "$raylib_rev"
git -C "$build" apply --check --whitespace=error /tmp/agnos/raylib-python.patch
git -C "$build" apply /tmp/agnos/raylib-python.patch
git -C "$build/raylib-c" apply --check --whitespace=error /tmp/agnos/raylib.patch
git -C "$build/raylib-c" apply /tmp/agnos/raylib.patch

python3 -m venv /tmp/raylib-venv
/tmp/raylib-venv/bin/pip install --no-cache-dir \
  setuptools==80.9.0 wheel==0.45.1 cffi==1.17.1 pycparser==2.22

make -C "$build/raylib-c/src" -j"$(nproc)" \
  PLATFORM=PLATFORM_COMMA GRAPHICS=GRAPHICS_API_OPENGL_ES3 RAYLIB_LIBTYPE=STATIC
cp "$build/raygui/src/raygui.h" "$build/raylib-c/src/"

cd "$build"
mkdir -p "$output"
cp LICENSE "$output/raylib-python-LICENSE"
cp raylib-c/LICENSE "$output/raylib-LICENSE"
cp raygui/LICENSE "$output/raygui-LICENSE"
cp /tmp/agnos/raylib-python.patch /tmp/agnos/raylib.patch "$output/"
{
  printf 'https://github.com/dorapilot/raylib-python-cffi %s\n' "$raylib_python_rev"
  git submodule status raylib-c raygui
  printf 'Local changes: raylib-python.patch raylib.patch\n'
  (cd "$output" && sha256sum raylib-python.patch raylib.patch)
} > "$output/SOURCES"

# Openpilot's C++ installer links the same COMMA backend statically.
mkdir -p raylib/install/{include,lib,share/doc/comma-deps-raylib}
cp raylib-c/src/{raylib.h,raymath.h,rlgl.h} raylib/install/include/
cp raylib-c/src/libraylib.a raylib/install/lib/libraylib_comma.a
cp "$output/"{*LICENSE*,*.patch,SOURCES} raylib/install/share/doc/comma-deps-raylib/

RAYLIB_PLATFORM=PLATFORM_COMMA \
RAYLIB_INCLUDE_PATH="$build/raylib-c/src" \
RAYLIB_LIB_PATH="$build/raylib-c/src" \
  /tmp/raylib-venv/bin/pip wheel --no-deps --no-build-isolation --wheel-dir "$output" .
