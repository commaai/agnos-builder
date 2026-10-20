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

# LLVM: keep clang, libLLVM (tinymesa, tinygrad), and the binutils-style tools.
llvm=/usr/lib/llvm-20
keep="clang clang++ clang-20 clang-cpp llvm-config llvm-objcopy llvm-strip llvm-ar llvm-ranlib llvm-nm
      llvm-objdump llvm-readobj llvm-readelf llvm-symbolizer llvm-addr2line llvm-dis llvm-as llvm-size"
for tool in "$llvm"/bin/*; do
  [[ " $(echo $keep) " == *" $(basename "$tool") "* ]] || rm "$tool"
done
find /usr/bin /usr/local/bin -xtype l -lname "*llvm-20*" -delete
# libclang is the C API, only used to regenerate tinygrad's autogen bindings. Polly is an unused plugin.
rm -f /usr/lib/aarch64-linux-gnu/libclang-20.so* "$llvm"/lib/libclang-20.so* "$llvm"/lib/LLVMPolly.so
# clang headers for other architectures and offload targets
inc=$(echo "$llvm"/lib/clang/*/include)
rm -rf "$inc"/{cuda,ppc,openmp,llvm_libc,llvm_offload,zos}_wrappers "$inc"/__clang_{cuda,hip}* \
  "$inc"/*{avx,sse,mmx,amx,x86,ia32}*intrin*.h "$inc"/{x86,ia32}intrin.h \
  "$inc"/{altivec,htm,htmxlintrin,s390intrin,vecintrin,msa,opencl-c,opencl-c-base}.h \
  "$inc"/{riscv,hexagon,hvx,wasm,lasx,lsx,larch}*

# libLLVM links libxml2, which links ICU (~38 MB), only for Windows manifest merging.
# Replace libxml2 with stubs; check they cover libLLVM and nothing else needs either library.
needed=$(llvm-nm -D --undefined-only "$lib"/libLLVM.so.20.1 | awk '/@LIBXML2/ {print $2}' | sort)
clang -shared -fPIC -O2 -Wl,--version-script=/tmp/agnos/libxml2_stub.map -Wl,-soname,libxml2.so.2 \
  -o /tmp/libxml2.so.2 /tmp/agnos/libxml2_stub.c
provided=$(llvm-nm -D --defined-only /tmp/libxml2.so.2 | awk '/@/ {sub("@@", "@", $3); print $3}' | sort)
missing=$(comm -23 <(echo "$needed") <(echo "$provided"))
[ -z "$missing" ] || { echo "libxml2 stub is missing: $missing"; exit 1; }
# aria2 is only used by apt-fast while building the image
rm -f /usr/bin/aria2c "$lib"/libaria2.so* /usr/local/sbin/apt-fast /etc/apt-fast.conf
rm -f "$lib"/libxml2.so* "$lib"/libicu*.so*
mv /tmp/libxml2.so.2 "$lib"/libxml2.so.2
# binutils readelf, since llvm-readelf stops at the first non-ELF file.
# /bin/true keeps it printing File: headers when xargs passes a single file.
users=$(find / -xdev -type f \( -name '*.so*' -o -perm -u+x \) -print0 | \
  xargs -0 readelf -d /bin/true 2>/dev/null | awk '/^File:/ {f=$2} /NEEDED.*(libxml2|libicu)/ {print f}' | sort -u)
[ "$users" = "$lib/libLLVM.so.20.1" ] || { echo "unexpected libxml2/ICU users: $users"; exit 1; }
