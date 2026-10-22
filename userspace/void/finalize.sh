#!/bin/bash -e
# Void-specific config fixups applied after the userspace/root overlay.
set -x

# --- core-services / stage 2 overrides for the read-only rootfs ---
install -m 644 /tmp/agnos/void/core-services/03-filesystems.sh /etc/runit/core-services/03-filesystems.sh
install -m 644 /tmp/agnos/void/core-services/04-agnos.sh /etc/runit/core-services/04-agnos.sh
install -m 755 /tmp/agnos/void/runit-2 /etc/runit/2
# 4.9 kernel: the cgroup2 nsdelegate mount option doesn't exist
sed -i 's/^#\?CGROUP_MODE=.*/CGROUP_MODE=legacy/' /etc/rc.conf
grep -q '^CGROUP_MODE=legacy' /etc/rc.conf || echo 'CGROUP_MODE=legacy' >> /etc/rc.conf

# --- systemd compatibility shims ---
install -m 755 /tmp/agnos/void/bin/* /usr/local/bin/

# --- NetworkManager: no systemd-resolved ---
sed -i 's/^dns=systemd-resolved/dns=default/' /etc/NetworkManager/NetworkManager.conf

# --- sshd: sftp-server path ---
sed -i 's|/usr/lib/openssh/sftp-server|/usr/libexec/sftp-server|' /etc/ssh/sshd_config

# --- iptables: legacy xtables backend (4.9 kernel has no nftables), rules from iptables-persistent's path ---
for t in iptables iptables-restore iptables-save ip6tables ip6tables-restore ip6tables-save; do
  ln -sf xtables-legacy-multi /usr/bin/$t
done
ln -sf rules.v4 /etc/iptables/iptables.rules

# --- python: venv uses a uv-managed 3.12, not the system python ---
sed -i 's/^export UV_PYTHON_PREFERENCE=only-system/export UV_PYTHON_PREFERENCE=only-managed/' /etc/profile

# --- adbd: bundled Ubuntu libs (Android libs' RUNPATH points at this dir) ---
patchelf --force-rpath --set-rpath /usr/lib/aarch64-linux-gnu/android /usr/comma/adbd

# ldconfig rewrites SONAME links back to glvnd/Mesa, so run it before the Adreno links
# (same ordering constraint as Dockerfile.agnos; nothing may run ldconfig afterwards)
ldconfig

# --- graphics: Adreno EGL/GLES/GBM instead of glvnd/Mesa (Void has no multiarch dir) ---
lib=/usr/lib/aarch64-linux-gnu
test -f $lib/libEGL_adreno.so
test -f $lib/libGLESv2_adreno.so
ln -sf $lib/libEGL_adreno.so $lib/libEGL.so.1
ln -sf $lib/libGLESv2_adreno.so $lib/libGLESv2.so.2
cp $lib/libgbm.so $lib/libgbm.so.1
for l in libEGL.so.1 libGLESv2.so.2 libgbm.so.1; do
  # /usr/lib wins over ld.so.conf dirs only via the cache; make it unambiguous
  ln -sf aarch64-linux-gnu/$l /usr/lib/$l
done
rm -f /usr/lib/libgallium-*.so /usr/lib/libEGL_mesa.so* /usr/lib/libGLX_mesa.so* /usr/lib/libgbm.so.1.*
rm -rf /usr/lib/dri /usr/lib/gbm
rm -f /usr/share/glvnd/egl_vendor.d/50_mesa.json

# --- runit services ---
/tmp/agnos/void/services.sh

# --- read-only rootfs (readonly_setup.sh equivalent) ---
rm -rf /etc/timezone /etc/localtime
ln -s /data/etc/timezone /etc/timezone
ln -s /data/etc/localtime /etc/localtime
rm -f /etc/ssh/ssh_host*
rm -rf /etc/NetworkManager/system-connections
ln -s /data/etc/NetworkManager/system-connections /etc/NetworkManager/system-connections
mkdir -p /usr/default
rm -rf /var/cache/*
mv /var /usr/default && mkdir /var
mv /home /usr/default && mkdir /home
rm -rf /tmp && mkdir -m 1777 /tmp
mkdir -p /cache /firmware /dsp /rwtmp
