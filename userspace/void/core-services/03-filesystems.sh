# AGNOS override of runit-void's 03-filesystems.sh.
# The rootfs is a read-only A/B system partition: never fsck or remount it rw,
# and never drop to an emergency shell when an optional mount fails.

[ -n "$IS_CONTAINER" ] && return 0

msg "AGNOS: leaving rootfs as mounted by the kernel"
msg "Mounting all non-network filesystems..."
mount -a -t "nosysfs,nonfs,nonfs4,nosmbfs,nocifs" -O no_netdev || msg_warn "mount -a had failures, continuing"
