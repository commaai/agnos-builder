#!/bin/bash

PATH=/usr/comma/shims:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

BOOTSH_RUN=/run/bootsh

log() {
  local ts="?"
  if [ -r /proc/uptime ]; then
    ts="$(cut -d' ' -f1 /proc/uptime)"
  fi

  printf 'boot.sh[%d]: %s %s\n' "$$" "$ts" "$*" >/dev/console 2>/dev/null || true
  printf '<6>boot.sh[%d]: %s %s\n' "$$" "$ts" "$*" >/dev/kmsg 2>/dev/null || true
}

mount_one() {
  local type="$1"
  local what="$2"
  local where="$3"
  shift 3

  mkdir -p "$where"
  mountpoint -q "$where" && return 0
  mount -t "$type" "$@" "$what" "$where" 2>/dev/kmsg
}

wait_block() {
  local dev="$1"
  local i

  for i in $(seq 1 150); do
    [ -b "$dev" ] && return 0
    sleep 0.01
  done

  log "timeout waiting for $dev"
  return 1
}

mount_block() {
  local what="$1"
  local where="$2"
  local type="$3"
  local opts="$4"

  wait_block "$what" || return 1
  mkdir -p "$where"
  mountpoint -q "$where" && return 0
  log "mount $where"
  mount -t "$type" -o "$opts" "$what" "$where" 2>/dev/kmsg
}

boost_early() {
  echo performance >/sys/devices/system/cpu/cpufreq/policy0/scaling_governor 2>/dev/null || true
  echo performance >/sys/devices/system/cpu/cpufreq/policy4/scaling_governor 2>/dev/null || true
  echo 2649600 >/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq 2>/dev/null || true
  echo 2649600 >/sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq 2>/dev/null || true
  echo 2649600 >/sys/devices/system/cpu/cpufreq/policy0/scaling_min_freq 2>/dev/null || true
  echo 2649600 >/sys/devices/system/cpu/cpufreq/policy4/scaling_min_freq 2>/dev/null || true
}

set_graphics_perms() {
  chgrp gpu /dev/adsprpc-smd /dev/ion /dev/kgsl-3d0 /dev/dri/* 2>/dev/null || true
  chmod 660 /dev/adsprpc-smd /dev/kgsl-3d0 /dev/dri/* 2>/dev/null || true
  chmod 664 /dev/ion 2>/dev/null || true
}

set_device_perms() {
  set_graphics_perms

  chgrp gpio /dev/i2c-* 2>/dev/null || true
  chmod 660 /dev/i2c-* 2>/dev/null || true
  chmod 666 /dev/spidev* 2>/dev/null || true
  chmod 666 /dev/input/* 2>/dev/null || true
  chgrp disk /dev/sd* 2>/dev/null || true
  chmod 660 /dev/sd* 2>/dev/null || true

  chgrp gpio /sys/class/gpio/gpio*/direction /sys/class/gpio/gpio*/value 2>/dev/null || true
  chmod 660 /sys/class/gpio/gpio*/direction /sys/class/gpio/gpio*/value 2>/dev/null || true

  chgrp video /sys/class/backlight/panel0-backlight/brightness \
    /sys/class/backlight/panel0-backlight/bl_power \
    /sys/devices/platform/soc/soc:qcom,dsi-display@0/max_brightness_percent 2>/dev/null || true
  chmod g+w /sys/class/backlight/panel0-backlight/brightness \
    /sys/class/backlight/panel0-backlight/bl_power \
    /sys/devices/platform/soc/soc:qcom,dsi-display@0/max_brightness_percent 2>/dev/null || true
}

permission_loop() {
  local i

  for i in $(seq 1 200); do
    set_device_perms
    sleep 0.025
  done
}

mount_data() {
  log "mount /data"
  mkdir -p /data
  mountpoint -q /data && return 0
  wait_block /dev/sda12 || return 1
  mount -t ext4 -o discard,noatime,nodiratime,nosuid,nodev /dev/sda12 /data 2>/dev/kmsg
}

data_late_setup() {
  mkdir -p /data/etc/netplan /data/etc/NetworkManager/system-connections /data/ssh /data/tmp /data/media
  chown comma:comma /data /data/media /data/ssh /data/tmp 2>/dev/null || true
  touch /data/etc/timezone /data/etc/localtime 2>/dev/null || true

  if [ ! -d /data/persist ] && [ -d /system/persist ]; then
    cp -a /system/persist /data/ 2>/dev/null || true
  fi
}

mount_early_state() {
  mount_one tmpfs tmpfs /var -o rw,nosuid,nodev,size=128M,mode=755 || true
  mount_one tmpfs tmpfs /tmp -o rw,nosuid,nodev,size=150M,mode=1777 || true
  mount_one tmpfs tmpfs /run -o nosuid,nodev,mode=755,size=714M,nr_inodes=819200 || true
  mount_one tmpfs tmpfs /rwtmp -o rw,nosuid,nodev,size=100M,mode=1777 || true

  mkdir -p "$BOOTSH_RUN" /var/tmp/xdg /var/log /run/sudo /run/user/1000 /rwtmp/home_work /rwtmp/home_upper
  chmod 1777 /var/tmp
  chown comma:comma /var/tmp/xdg /run/user/1000 2>/dev/null || true
  chmod 700 /run/user/1000 2>/dev/null || true

  mount_one tmpfs tmpfs /var/log -o rw,nosuid,nodev,size=128M,mode=755 || true
  systemd-tmpfiles --create /usr/comma/tmpfiles.conf >/tmp/bootsh-tmpfiles.log 2>&1 || true

  mountpoint -q /home || mount -t overlay overlay \
    -o lowerdir=/usr/default/home,upperdir=/rwtmp/home_upper,workdir=/rwtmp/home_work \
    /home 2>/dev/kmsg || true
}

mount_core() {
  mount_one proc proc /proc || true
  mount_one sysfs sysfs /sys || true
  mount_one devtmpfs devtmpfs /dev -o mode=755 || true
  mkdir -p /dev/pts /dev/shm /sys/fs/cgroup /sys/fs/pstore /sys/fs/bpf /sys/kernel/debug /sys/kernel/tracing /sys/kernel/config
  mount_one devpts devpts /dev/pts -o gid=5,mode=620,ptmxmode=000 || true
  mount_one tmpfs tmpfs /dev/shm -o nosuid,nodev,size=1800M || true
}

mount_firmware() {
  mount_block /dev/sde4 /firmware vfat ro || true
  mount_block /dev/sde9 /dsp ext4 ro || true
  log "firmware mounts done"
}

mount_deferred() {
  mount_one tmpfs tmpfs /run/lock -o nosuid,nodev,noexec,size=5M || true
  mount_one cgroup2 cgroup2 /sys/fs/cgroup -o nosuid,nodev,noexec || true
  mount_one pstore pstore /sys/fs/pstore -o nosuid,nodev,noexec || true
  mount_one bpf bpf /sys/fs/bpf -o nosuid,nodev,noexec || true
  mount_one debugfs debugfs /sys/kernel/debug -o nosuid,nodev,noexec || true
  mount_one tracefs tracefs /sys/kernel/tracing -o nosuid,nodev,noexec || true
  mount_one configfs configfs /sys/kernel/config || true
  ln -sf /sys/kernel/tracing /sys/kernel/debug/tracing 2>/dev/null || true

  mount_firmware
  mount_block /dev/sda2 /persist squashfs ro,nosuid,nodev,noexec || true
  mount_block /dev/sda10 /systemrw ext4 relatime,data=ordered,noauto_da_alloc,discard,noexec,nodev || true
  mount_block /dev/sda11 /cache ext4 relatime,data=ordered,noauto_da_alloc,discard,noexec,nodev,nosuid || true
  chown -R comma:comma /cache 2>/dev/null || true
  log "deferred mounts done"
}

setup_input_links() {
  local event i name

  for i in $(seq 1 250); do
    for event in /sys/class/input/event*; do
      [ -r "$event/device/name" ] || continue
      name="$(cat "$event/device/name" 2>/dev/null || true)"
      if [ "$name" = "fts_ts" ]; then
        mkdir -p /dev/input/by-path
        ln -sf "../$(basename "$event")" /dev/input/by-path/platform-894000.i2c-event
        log "input link ready"
        return 0
      fi
    done
    sleep 0.02
  done

  log "timeout waiting for touch input"
}

setup_gpios() {
  local p i pins

  pins="30 49 134 41 50 116 124 34 33 32 52 1264"
  for p in $pins; do
    if [ "$p" = "41" ] && grep -q "comma tici" /sys/firmware/devicetree/base/model 2>/dev/null; then
      continue
    fi
    [ -d "/sys/class/gpio/gpio$p" ] || echo "$p" >/sys/class/gpio/export 2>/dev/null || true
  done

  for p in $pins; do
    if [ "$p" = "41" ] && grep -q "comma tici" /sys/firmware/devicetree/base/model 2>/dev/null; then
      continue
    fi
    for i in $(seq 1 20); do
      [ -d "/sys/class/gpio/gpio$p" ] && break
      sleep 0.005
    done
  done

  echo out >/sys/class/gpio/gpio30/direction 2>/dev/null || true
  echo 1 >/sys/class/gpio/gpio30/value 2>/dev/null || true
  set_device_perms
  touch "$BOOTSH_RUN/gpio-ready"
  log "gpio ready"
}

make_bootdevice_links() {
  local dev i key part uevent value

  mkdir -p /dev/block/bootdevice/by-name /dev/disk/by-partlabel
  for i in $(seq 1 150); do
    for uevent in /sys/class/block/sd*[0-9]*/uevent; do
      [ -e "$uevent" ] || continue
      dev="${uevent#/sys/class/block/}"
      dev="${dev%/uevent}"
      part=""
      while IFS='=' read -r key value; do
        if [ "$key" = "PARTNAME" ]; then
          part="$value"
          break
        fi
      done <"$uevent"
      if [ -n "$part" ]; then
        ln -sf "/dev/$dev" "/dev/block/bootdevice/by-name/$part"
        ln -sf "/dev/$dev" "/dev/disk/by-partlabel/$part"
      fi
    done
    [ -e /dev/block/bootdevice/by-name/modemst1 ] && break
    sleep 0.02
  done
  log "bootdevice links ready"
}

qcom_early() {
  local f

  for f in /sys/bus/msm_subsys/devices/subsys*/restart_level; do
    [ -e "$f" ] && echo related >"$f" 2>/dev/null || true
  done

  boost_early
  [ -x /usr/bin/irsc_util ] && /usr/bin/irsc_util /etc/sec_config >/tmp/irsc_util.log 2>&1 || true
  [ -e /sys/kernel/boot_cdsp/boot ] && echo 1 >/sys/kernel/boot_cdsp/boot 2>/dev/null || true
  [ -e /dev/ipa ] && echo 1 >/dev/ipa 2>/dev/null || true
  log "qcom early done"
}

start_magic() {
  log "start magic"
  /usr/comma/start-magic.sh >/tmp/magic.log 2>&1 &
  touch "$BOOTSH_RUN/magic-started"
}

start_comma() {
  log "start comma"
  /usr/comma/start-comma.sh >/tmp/comma-start.log 2>&1
  log "comma launched"
}

start_sound() {
  log "start sound"
  /usr/comma/sound/start-sound.sh --boot >/tmp/sound.log 2>&1 &
}

handoff_systemd() {
  log "exec systemd"
  exec /usr/lib/systemd/systemd

  log "systemd exec failed; staying in pid1 reap loop"
  while true; do
    wait -n || true
    set_device_perms
    sleep 0.25
  done
}

log "pid1 start"

mount_core
boost_early
mount_data &
data_mount_pid=$!

mount_early_state
permission_loop &
setup_gpios &
gpio_pid=$!
setup_input_links &
start_magic

wait "$data_mount_pid" || true
data_late_setup
touch "$BOOTSH_RUN/data-ready"

start_comma

mount_deferred &
mount_deferred_pid=$!
qcom_early &
qcom_early_pid=$!
make_bootdevice_links &
bootdevice_pid=$!

wait "$mount_deferred_pid" || true
touch "$BOOTSH_RUN/fs-setup-done"
start_sound

wait "$qcom_early_pid" || true
wait "$bootdevice_pid" || true
wait "$gpio_pid" || true
set_device_perms

log "boot path done"
handoff_systemd
