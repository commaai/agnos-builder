#!/bin/bash -e

site=/usr/local/venv/lib/python3.12/site-packages

# GNU strip corrupts the layout of the patched tinymesa libraries.
find "$site"/{tinymesa,capnp,zstandard,kiwisolver,fontTools} -type f -name '*.so' \
  -exec llvm-strip --strip-debug {} +

# Keep runtime helpers such as numpy.testing and sympy.testing.
find "$site"/{sympy,numpy,matplotlib,mpmath,setuptools} -type d \( -name tests -o -name test \) \
  -prune -exec rm -rf {} +

# Unused LLVM: the libclang C API (tinygrad only uses it to regenerate bindings),
# the Polly plugin, and the largest test/debug tools.
llvm=/usr/lib/llvm-20
rm -f /usr/lib/aarch64-linux-gnu/libclang-20.so* $llvm/lib/libclang-20.so* $llvm/lib/LLVMPolly.so \
  $llvm/bin/{obj2yaml,yaml2obj,llvm-tblgen,llvm-jitlink-executor,lli-child-target,llvm-pdbutil,llvm-exegesis}
find /usr/bin /usr/local/bin -xtype l -delete

# AGNOS uses Adreno EGL/GLES/GBM. Keep LLVM20 for tinymesa's CPU compiler.
lib=/usr/lib/aarch64-linux-gnu
rm -f "$lib"/libgallium-*.so "$lib"/libEGL_mesa.so* "$lib"/libGLX_mesa.so* "$lib"/libgbm.so.1.0.0
rm -rf "$lib"/dri "$lib"/gbm
rm /usr/share/glvnd/egl_vendor.d/50_mesa.json
