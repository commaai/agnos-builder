#!/bin/bash

PATH=/usr/sbin:/usr/bin:/sbin:/bin

log() {
  echo "fs_setup[$$]: $(cut -d' ' -f1 /proc/uptime) $*" > /dev/kmsg
}

wait_for_block() {
  local device="$1"
  local i

  for ((i = 0; i < 200; i++)); do
    if [[ -b "$device" ]]; then
      return 0
    fi
    sleep 0.01
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

# Create /dev/block/bootdevice/by-name/* ahead of udev so rmt_storage doesn't
# block ~8s waiting for udev to settle on the modem partitions.
make_bootdevice_links() {
  mkdir -p /dev/block/bootdevice/by-name
  for ((i = 0; i < 200; i++)); do
    for uevent in /sys/class/block/sd*[0-9]*/uevent; do
      [ -e "$uevent" ] || continue
      dev=${uevent#/sys/class/block/}; dev=${dev%/uevent}
      while IFS='=' read -r k v; do
        [ "$k" = "PARTNAME" ] && ln -sf "/dev/$dev" "/dev/block/bootdevice/by-name/$v" && break
      done <"$uevent"
    done
    [ -e /dev/block/bootdevice/by-name/modemst1 ] && return 0
    sleep 0.01
  done
  log "timed out creating bootdevice links"
  return 1
}

log "start"

make_bootdevice_links &
mount_fs /dev/sde9 /dsp ext4 ro &
mount_fs /dev/sde4 /firmware vfat ro &
mount_fs /dev/sda2 /persist squashfs ro,nosuid,nodev,noexec &
mount_fs /dev/sda10 /systemrw ext4 relatime,data=ordered,noauto_da_alloc,discard,noexec,nodev &
mount_fs /dev/sda12 /data ext4 discard,noatime,nodiratime,nosuid,nodev &
mount_fs /dev/sda11 /cache ext4 relatime,data=ordered,noauto_da_alloc,discard,noexec,nodev,nosuid &
mount_fs tmpfs /var tmpfs rw,nosuid,nodev,size=128M,mode=755 &
mount_fs tmpfs /tmp tmpfs rw,nosuid,nodev,size=150M,mode=1777 &
mount_fs tmpfs /rwtmp tmpfs rw,nosuid,nodev,size=100M,mode=1777 &
wait

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

if ! mountpoint -q /data; then
  log "data mount failed"
  exit 1
fi

log "done"
