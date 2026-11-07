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

# udev isn't used, see boot.sh. NetworkManager and others still depend on the package.
dpkg --purge --force-depends udev
rm -rf /usr/lib/udev /etc/udev

# systemd loads every unit it can reach before it starts the first job, about 1 ms each at boot.
# AGNOS has no initrd, TPM, encrypted or verity disks, sysext, fsck or binfmt, so drop their units.
cd /usr/lib/systemd/system
rm -rf initrd* systemd-pcr* systemd-tpm2* systemd-repart* systemd-firstboot* systemd-sysext* systemd-bsod* \
  systemd-battery-check* systemd-hibernate-resume* systemd-soft-reboot* soft-reboot.target systemd-fsck* \
  remote-* cryptsetup* veritysetup* integritysetup* systemd-binfmt* proc-sys-fs-binfmt*
find . -xtype l -delete

# goes over loglevel=3 from the kernel cmdline, the serial console is slow enough that printing errors stalls boot
rm /etc/sysctl.d/10-console-messages.conf
