#!/bin/bash -e
# trim.sh, ported: same trimming the Ubuntu image gets.
site=/usr/local/venv/lib/python3.12/site-packages

# GNU strip corrupts the layout of the patched tinymesa libraries.
# llvm-strip is in the llvm20 tools package, only needed here.
apk add --no-cache --virtual .llvm-strip llvm20
find "$site"/{tinymesa,capnp,zstandard,kiwisolver,fontTools} -type f -name '*.so' \
  -exec /usr/lib/llvm20/bin/llvm-strip --strip-debug {} +
apk del .llvm-strip

# Keep runtime helpers such as numpy.testing and sympy.testing.
find "$site"/{sympy,numpy,matplotlib,mpmath,setuptools} -type d \( -name tests -o -name test \) \
  -prune -exec rm -rf {} +

# These inspection/benchmark tools are not used by GCC or clang to compile.
rm -f /usr/bin/*lto-dump* /usr/libexec/gcc/*/*/lto-dump* /usr/lib/llvm20/bin/llvm-exegesis /usr/local/bin/llvm-exegesis
