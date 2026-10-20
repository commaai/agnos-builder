#!/bin/bash -e

site=/usr/local/venv/lib/python3.12/site-packages

# GNU strip corrupts the layout of the patched tinymesa libraries.
find "$site"/{tinymesa,capnp,zstandard,kiwisolver,fontTools} -type f -name '*.so' \
  -exec llvm-strip --strip-debug {} +

# Keep runtime helpers such as numpy.testing and sympy.testing.
find "$site"/{sympy,numpy,matplotlib,mpmath,setuptools} -type d \( -name tests -o -name test \) \
  -prune -exec rm -rf {} +

# This benchmark tool is not used by clang to compile.
rm -f /usr/bin/llvm-exegesis* /usr/lib/llvm-*/bin/llvm-exegesis

# AGNOS uses Adreno EGL/GLES/GBM. Keep LLVM20 for tinymesa's CPU compiler.
lib=/usr/lib/aarch64-linux-gnu
rm -f "$lib"/libgallium-*.so "$lib"/libEGL_mesa.so* "$lib"/libGLX_mesa.so* "$lib"/libgbm.so.1.0.0
rm -rf "$lib"/dri "$lib"/gbm
rm /usr/share/glvnd/egl_vendor.d/50_mesa.json
