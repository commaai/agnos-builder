#!/bin/bash -e
# SPIKE: squeeze the image beyond trim.sh, for the Ubuntu vs Alpine size
# comparison. Opt-in with SQUEEZE=1 ./build_system.sh (either distro).
# Cuts are tagged:
#  [both]   applied to Ubuntu and Alpine alike
#  [ubuntu] packages AGNOS installs on Ubuntu that the Alpine build never had
#  [alpine] Alpine packaging overhead the Ubuntu image doesn't carry
site=/usr/local/venv/lib/python3.12/site-packages

if [ -f /etc/alpine-release ]; then
  apk add --no-cache --virtual .squeeze llvm20 binutils
  LLVM_STRIP=/usr/lib/llvm20/bin/llvm-strip
else
  LLVM_STRIP=/usr/lib/llvm-20/bin/llvm-strip
fi

# [both] debug info in Python wheels (casadi, raylib, cryptography, ...).
# llvm-strip: GNU strip corrupts the patched tinymesa libraries.
find "$site" /usr/local/venv/bin -type f \( -name '*.so' -o -name '*.so.*' -o -perm -u+x \) -print0 | \
  xargs -0 sh -c 'for f; do if [ "$(head -c4 "$f" | tr -d "\0")" = "$(printf "\177ELF")" ]; then '"$LLVM_STRIP"' --strip-debug "$f"; fi; done' sh

# [both] static libpython: only for embedding Python into a statically linked binary
rm -f /usr/lib/python3.12/config-3.12-*/libpython3.12*.a

# [both] GCC's LTO backend; openpilot doesn't build with -flto
rm -f /usr/libexec/gcc/*/*/lto1 /usr/libexec/gcc/*/*/lto-wrapper

# [both] vim runtime docs, tutor, spell files, translations
rm -rf /usr/share/vim/vim*/{doc,tutor,spell,lang,keymap,print}

# [both] Python linters from openpilot[testing], not used on device
rm -f /usr/local/venv/bin/ruff /usr/local/venv/bin/ty

# [both] stdlib modules nothing on device uses
rm -rf /usr/lib/python3.12/{lib2to3,idlelib,pydoc_data,turtledemo,ensurepip}

# [both] clang's x86/CUDA/HIP/PowerPC headers, never used on aarch64
inc=$(echo /usr/lib/llvm*/lib/clang/*/include)
rm -rf "$inc"/{cuda_wrappers,ppc_wrappers,openmp_wrappers,llvm_libc_wrappers} "$inc"/__clang_{cuda,hip}* \
  "$inc"/*{avx,sse,mmx,amx,x86,ia32}*intrin*.h "$inc"/{x86,ia32}intrin.h

if [ -f /etc/alpine-release ]; then
  # [alpine] Alpine doesn't strip static libraries (libc.a, libstdc++.a, ...)
  find /usr/lib -name '*.a' -type f -exec strip --strip-debug {} +

  # [alpine] glib-dev's docbook/gettext/gtk-doc and GObject introspection data, only used to build docs/bindings
  rm -rf /usr/share/xml /usr/share/gir-1.0 /usr/share/gtk-doc /usr/share/gettext /usr/share/aclocal

  # [alpine] GCC plugin headers (Ubuntu splits them into gcc-*-plugin-dev)
  rm -rf /usr/lib/gcc/*/*/plugin

  # [alpine] musl debug symbols, pulled in by gdb
  rm -rf /usr/lib/debug

  # [alpine] musllinux wheels each bundle libstdc++/libgcc_s (manylinux uses the system's).
  # Point them at Alpine's: GCC 15's libstdc++ is newer than the wheels' 6.0.33.
  find "$site" -path '*.libs/*' -name 'libstdc++-*.so*' -exec ln -sf /usr/lib/libstdc++.so.6 {} \;
  find "$site" -path '*.libs/*' -name 'libgcc_s-*.so*' -exec ln -sf /usr/lib/libgcc_s.so.1 {} \;

  apk del .squeeze
else
  # [ubuntu] crash reporter (and the libc6-dbg it pulls in) and the apt-fast build tool; the Alpine build has none.
  # The LLVM 20 tools: tinymesa only needs libLLVM, and Alpine installs just the libraries.
  # Runs before the ldconfig + Adreno link step in Dockerfile.agnos (apt triggers ldconfig).
  # trim.sh still needs llvm-strip (a small binary on top of libLLVM, which clang keeps)
  cp /usr/lib/llvm-20/bin/llvm-strip /tmp/llvm-strip
  # libc6-dbg is marked manual, so autoremove keeps it. apt-fast/aria2 are build-time only.
  apt-get purge -yq apport apport-retrace apport-core-dump-handler libc6-dbg llvm-20 aria2
  apt-get autoremove -yq --purge
  rm -f /usr/local/sbin/apt-fast /etc/apt-fast.conf
  find /usr/local/bin -xtype l -delete
  mv /tmp/llvm-strip /usr/local/bin/llvm-strip
  rm -rf /var/lib/apt/lists/*
fi
