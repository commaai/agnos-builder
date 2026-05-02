#!/bin/bash

PATH=/usr/sbin:/usr/bin:/sbin:/bin

log() {
  echo "fs_setup[$$]: $(cut -d' ' -f1 /proc/uptime) $*" > /dev/kmsg
}

wait_for_block() {
  local device="$1"
  local i

  for ((i = 0; i < 150; i++)); do
    if [[ -b "$device" ]]; then
      return 0
    fi
    sleep 0.02
  done

  log "timed out waiting for $device"
  return 1
}

mount_fs() {
  local what="$1"
  local where="$2"
  local type="$3"
  local options="$4"

  if [[ "$what" == /dev/* ]] && ! wait_for_block "$what"; then
    failed=1
    return 1
  fi

  log "mounting $where"
  if mount --mkdir -t "$type" -o "$options" "$what" "$where"; then
    log "mounted $where"
    return 0
  fi

  log "failed mounting $where"
  failed=1
  return 1
}

create_bootdevice_links() {
  # this is just needed for rmt_storage
  # can probably be removed once we go mainline

  local failed_links

  log "creating bootdevice links"
  mkdir -p /dev/block/bootdevice/by-name

  failed_links=0
  wait_for_block /dev/sdf2 && ln -sf /dev/sdf2 /dev/block/bootdevice/by-name/modemst1 || failed_links=1
  wait_for_block /dev/sdf3 && ln -sf /dev/sdf3 /dev/block/bootdevice/by-name/modemst2 || failed_links=1
  wait_for_block /dev/sdf4 && ln -sf /dev/sdf4 /dev/block/bootdevice/by-name/fsg || failed_links=1
  wait_for_block /dev/sdf5 && ln -sf /dev/sdf5 /dev/block/bootdevice/by-name/fsc || failed_links=1

  if [[ "$failed_links" -ne 0 ]]; then
    log "failed creating bootdevice links"
    failed=1
    return 1
  fi

  log "created bootdevice links"
}

log "start"

failed=0
mount_fs /dev/sde9 /dsp ext4 ro
mount_fs /dev/sde4 /firmware vfat ro
mount_fs /dev/sda2 /persist squashfs ro,nosuid,nodev,noexec
mount_fs /dev/sda10 /systemrw ext4 relatime,data=ordered,noauto_da_alloc,discard,noexec,nodev
mount_fs /dev/sda12 /data ext4 discard,noatime,nodiratime,nosuid,nodev
mount_fs /dev/sda11 /cache ext4 relatime,data=ordered,noauto_da_alloc,discard,noexec,nodev,nosuid
create_bootdevice_links
mount_fs tmpfs /var tmpfs rw,nosuid,nodev,size=128M,mode=755
mount_fs tmpfs /tmp tmpfs rw,nosuid,nodev,size=150M,mode=1777
mount_fs tmpfs /rwtmp tmpfs rw,nosuid,nodev,size=100M,mode=1777

# Ensure the symlinks in the read only rootfs are
# backed by real files and directories on userdata.

# tmpfiles
systemd-tmpfiles --create /usr/comma/tmpfiles.conf

# /var/log/ tmpfs
mkdir -p /var/log/
chown root:syslog /var/log
mount -t tmpfs -o rw,nosuid,nodev,size=128M,mode=755 tmpfs /var/log

# setup /home
mkdir -p /rwtmp/home_work
mkdir -p /rwtmp/home_upper
chmod 755 /rwtmp/*
mount -t overlay overlay -o lowerdir=/usr/default/home,upperdir=/rwtmp/home_upper,workdir=/rwtmp/home_work /home

# /etc
mkdir -p /data/etc
touch /data/etc/timezone
touch /data/etc/localtime
mkdir -p /data/etc/netplan
mkdir -p /data/etc/NetworkManager/system-connections

# /cache
chown -R comma:comma /cache/

# /data/ssh
mkdir -p /data/ssh
chown comma: /data/ssh

# /data/tmp - clear out
rm -rf /data/tmp/
mkdir -p /data/tmp/

# /data/persist
if [[ ! -d /data/persist ]]; then
  sudo cp -r /system/persist /data
fi

if [[ "$failed" -ne 0 ]]; then
  log "mounts failed"
  exit 1
fi

log "done"
