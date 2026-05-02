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
    return 1
  fi

  log "mounting $where"
  if mount --mkdir -t "$type" -o "$options" "$what" "$where"; then
    log "mounted $where"
    return 0
  fi

  log "failed mounting $where"
  return 1
}

log "start"

failed=0
mount_fs /dev/sde9 /dsp ext4 ro || failed=1
mount_fs /dev/sde4 /firmware vfat ro || failed=1
mount_fs /dev/sda2 /persist squashfs ro,nosuid,nodev,noexec || failed=1
mount_fs /dev/sda10 /systemrw ext4 relatime,data=ordered,noauto_da_alloc,discard,noexec,nodev || failed=1
mount_fs /dev/sda12 /data ext4 discard,noatime,nodiratime,nosuid,nodev || failed=1
mount_fs /dev/sda11 /cache ext4 relatime,data=ordered,noauto_da_alloc,discard,noexec,nodev,nosuid || failed=1
mount_fs tmpfs /var tmpfs rw,nosuid,nodev,size=128M,mode=755 || failed=1
mount_fs tmpfs /tmp tmpfs rw,nosuid,nodev,size=150M,mode=1777 || failed=1
mount_fs tmpfs /rwtmp tmpfs rw,nosuid,nodev,size=100M,mode=1777 || failed=1

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
