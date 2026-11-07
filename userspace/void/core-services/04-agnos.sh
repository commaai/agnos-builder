# AGNOS: read-only rootfs setup, replaces fs_setup.service + serial-hostname.service
[ -n "$IS_CONTAINER" ] && return 0

# /var is a tmpfs; repopulate from the build-time copy. The xbps pkgdb stays on the rootfs.
if mountpoint -q /var; then
    msg "AGNOS: populating /var from /usr/default/var..."
    tar -C /usr/default/var --exclude=./db/xbps --exclude=./cache -cf - . | tar -C /var -xpf -
    mkdir -p /var/db /var/cache
    ln -sfn /usr/default/var/db/xbps /var/db/xbps
fi
[ -L /var/service ] || ln -sfn ../run/runit/runsvdir/current /var/service

msg "AGNOS: fs_setup..."
/usr/comma/fs_setup.sh

msg "AGNOS: hostname from serial..."
/usr/comma/set-hostname.sh || msg_warn "set-hostname failed"
