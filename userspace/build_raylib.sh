#!/bin/bash
set -euo pipefail

# comma-deps-raylib 6.0.0.1.post106 (cffi and nanobind bindings), built from
# the commaai/dependencies revision that published it. Only the COMMA backend
# is built, with raylib.patch for the mainline display and touchscreen and for
# GPU mipmaps of GRAY_ALPHA textures (the UI's font atlases) on Mesa, so the
# wheel carries the local version label +agnos. That still satisfies
# ==6.0.0.1.post106, but nobody can mistake it for the PyPI wheel.
dependencies_rev=52bdb390b147499d7a6d8cb91ca40ec8b0b2f52d
post=106  # git rev-list --count of dependencies_rev, as its build.sh computes it
raylib_rev=0f2319ad94ea31acfeb3fdce6c5725a14f545f74
patch=/tmp/agnos/raylib.patch
build=/tmp/dependencies
output=/tmp/agnos/raylib

fetch() {
  git init -q "$2"
  git -C "$2" remote add origin "$1"
  git -C "$2" fetch -q --depth=1 origin "$3"
  git -C "$2" checkout -q --detach FETCH_HEAD
}

fetch https://github.com/commaai/dependencies.git "$build" "$dependencies_rev"
cd "$build/raylib"
grep -qx "RAYLIB_COMMIT=\"$raylib_rev\"" build.sh
fetch https://github.com/commaai/raylib.git raylib-src "$raylib_rev"
git -C raylib-src apply --check "$patch"

# build.sh resets raylib-src to the pinned commit; apply the patch after that.
sed -i "/^git reset --hard \"\$RAYLIB_COMMIT\"$/a git apply $patch" build.sh
grep -q "^git apply $patch$" build.sh
# The rendering test needs the device's display, which the COMMA backend opens.
sed -i 's/RAYLIB_TEST_RENDER="1" if platform.system() == "Linux" else "0"/RAYLIB_TEST_RENDER="0"/' setup.py
grep -q 'RAYLIB_TEST_RENDER="0"' setup.py

python3 -m venv /tmp/raylib-venv
/tmp/raylib-venv/bin/pip install -q --no-cache-dir \
  setuptools==80.9.0 cffi==1.17.1 pycparser==2.22 nanobind==3.1.0
python3 ../build_versions.py apply "$post" pyproject.toml
sed -i "s/^version = \"\(.*\.post$post\)\"$/version = \"\1+agnos\"/" pyproject.toml
grep -qx "version = \".*\.post$post+agnos\"" pyproject.toml
RAYLIB_BACKEND=comma /tmp/raylib-venv/bin/pip wheel -q --no-deps --no-build-isolation --wheel-dir "$output" .

mkdir -p "$output/doc"
cp "$patch" raylib-src/LICENSE "$output/doc/"
cat > "$output/doc/SOURCES" <<EOF
https://github.com/commaai/dependencies $dependencies_rev (raylib, .post$post)
https://github.com/commaai/raylib $raylib_rev with raylib.patch
Only the COMMA backend is built.
EOF
