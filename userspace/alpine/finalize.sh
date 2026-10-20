#!/bin/bash -e
# Alpine-specific config fixups applied after the userspace/root overlay.
set -x
A=/tmp/agnos/alpine

# --- init: runit as pid 1, with our stages ---
install -d /etc/runit/runsvdir/default
install -m 755 $A/runit/1 $A/runit/2 $A/runit/3 /etc/runit/
# runit-init toggles these to reboot/poweroff; /etc is read-only
ln -sfn /run/runit/stopit /etc/runit/stopit
ln -sfn /run/runit/reboot /etc/runit/reboot
ln -sfn /sbin/runit-init /sbin/init

# --- systemd compatibility shims, reboot/poweroff for runit ---
install -m 755 $A/bin/systemctl $A/bin/systemd-cat $A/bin/systemd-tmpfiles /usr/local/bin/
install -d /usr/local/sbin
install -m 755 $A/bin/reboot /usr/local/sbin/reboot
ln -sf reboot /usr/local/sbin/poweroff
ln -sf reboot /usr/local/sbin/halt

# --- NetworkManager: no systemd-resolved ---
sed -i 's/^dns=systemd-resolved/dns=default/' /etc/NetworkManager/NetworkManager.conf

# --- sshd: sftp-server path ---
sed -i 's|/usr/lib/openssh/sftp-server|/usr/lib/ssh/sftp-server|' /etc/ssh/sshd_config

# --- iptables: legacy xtables backend (4.9 kernel has no nftables) ---
for t in iptables iptables-restore iptables-save ip6tables ip6tables-restore ip6tables-save; do
  ln -sf xtables-legacy-multi /sbin/$t
done

# --- adbd: bundled Ubuntu Android libs ---
apk add --no-cache --virtual .patchelf patchelf
patchelf --force-rpath --set-rpath /usr/lib/aarch64-linux-gnu/android /usr/comma/adbd
apk del .patchelf

# --- graphics: Adreno EGL/GLES/GBM (glibc, see the glibc island in Dockerfile.alpine) ---
lib=/usr/lib/aarch64-linux-gnu
test -f $lib/libEGL_adreno.so
test -f $lib/libGLESv2_adreno.so
ln -sf libEGL_adreno.so $lib/libEGL.so.1
ln -sf libGLESv2_adreno.so $lib/libGLESv2.so.2
cp $lib/libgbm.so $lib/libgbm.so.1
for l in libEGL.so.1 libGLESv2.so.2 libgbm.so.1; do
  ln -sf aarch64-linux-gnu/$l /usr/lib/$l
  ln -sf aarch64-linux-gnu/$l /usr/lib/${l%.*}
done

# --- runit services ---
$A/services.sh

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
