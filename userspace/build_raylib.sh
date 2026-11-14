#!/bin/bash
set -euo pipefail

# The COMMA backend of comma-deps-raylib 6.0.0.1.post112 (cffi and nanobind
# bindings), built from the commaai/dependencies revision that published it,
# with raylib.patch for the mainline display and touchscreen. Only the
# backend's two extension modules are kept: the Dockerfile puts them over the
# PyPI wheel's and the UI apps' copies, which present through the downstream
# kernel's ION and rotator.
dependencies_rev=82b884ed7b53fce868ee37bb685675d58a07003f
raylib_rev=b9dd5bb71f83ea1c3d32a7ba5a8ec9e211983679
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
# Its tests run on the backend that's built, and the COMMA one needs the device's display. They run in
# commaai/dependencies, on the headless backend.
sed -i 's/^\( *\)subprocess.check_call(\[sys.executable, "-m", "unittest", .*/\1pass/' setup.py
! grep -q '"-m", "unittest"' setup.py

python3 -m venv /tmp/raylib-venv
/tmp/raylib-venv/bin/pip install -q --no-cache-dir \
  setuptools==80.9.0 cffi==1.17.1 pycparser==2.22 nanobind==3.1.0 numpy==2.2.6
RAYLIB_BACKEND=comma /tmp/raylib-venv/bin/pip wheel -q --no-deps --no-build-isolation --wheel-dir /tmp/raylib-wheel .

mkdir -p "$output/doc"
python3 -m zipfile -e /tmp/raylib-wheel/*.whl /tmp/raylib-wheel/files
cp /tmp/raylib-wheel/files/*.data/purelib/raylib/_raylib_cffi_comma.abi3.so \
  /tmp/raylib-wheel/files/*.data/purelib/raylib_nb/_raylib_comma.abi3.so "$output/"
cp "$patch" raylib-src/LICENSE "$output/doc/"
cat > "$output/doc/SOURCES" <<EOF
https://github.com/commaai/dependencies $dependencies_rev (raylib, .post112)
https://github.com/commaai/raylib $raylib_rev with raylib.patch
Only the COMMA backend is built.
EOF
