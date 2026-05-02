#!/bin/bash

set -e

PATH=/usr/sbin:/usr/bin:/sbin:/bin

shopt -s nullglob

log() {
  echo "permissions[$$]: $(cut -d' ' -f1 /proc/uptime) $*" > /dev/kmsg
}

set_mode() {
  local mode="$1"
  shift

  for path in "$@"; do
    if [[ -e "$path" ]]; then
      chmod "$mode" "$path"
    fi
  done
}

set_group_mode() {
  local group="$1"
  local mode="$2"
  shift 2

  for path in "$@"; do
    if [[ -e "$path" ]]; then
      chgrp "$group" "$path"
      chmod "$mode" "$path"
    fi
  done
}

set_group_writable() {
  local group="$1"
  shift

  for path in "$@"; do
    if [[ -e "$path" ]]; then
      chgrp "$group" "$path"
      chmod g+w "$path"
    fi
  done
}

set_usb_mode() {
  local vendor="$1"
  local product="$2"
  local mode="$3"
  local devdir devnode

  for devdir in /sys/bus/usb/devices/*; do
    [[ -f "$devdir/idVendor" && -f "$devdir/idProduct" ]] || continue
    [[ "$(< "$devdir/idVendor")" == "$vendor" ]] || continue
    [[ "$(< "$devdir/idProduct")" == "$product" ]] || continue
    [[ -f "$devdir/busnum" && -f "$devdir/devnum" ]] || continue

    printf -v devnode "/dev/bus/usb/%03d/%03d" "$(< "$devdir/busnum")" "$(< "$devdir/devnum")"
    if [[ -e "$devnode" ]]; then
      chmod "$mode" "$devnode"
    else
      log "missing $devnode for usb $vendor:$product"
    fi
  done
}

create_touch_input_link() {
  local event name

  mkdir -p /dev/input/by-path
  for event in /sys/class/input/event*; do
    [[ -f "$event/device/name" ]] || continue
    name="$(< "$event/device/name")"
    if [[ "$name" == "fts_ts" ]]; then
      ln -sf "../$(basename "$event")" /dev/input/by-path/platform-894000.i2c-event
      return 0
    fi
  done

  log "missing fts_ts input event"
}

log "start"

# 50-log.rules
set_mode 666 /dev/binder
set_mode 644 /dev/log_main /dev/log_radio /dev/log_system /dev/log_events

# 93-input.rules plus the by-path link openpilot uses.
set_mode 666 /dev/input/event* /dev/input/mice /dev/input/mouse*
create_touch_input_link

# 94-backlight.rules
set_group_writable video \
  /sys/class/backlight/panel0-backlight/brightness \
  /sys/class/backlight/panel0-backlight/bl_power \
  /sys/devices/platform/soc/soc:qcom,dsi-display@0/max_brightness_percent \
  /sys/class/leds/led:torch_2/brightness \
  /sys/class/leds/led:switch_2/brightness

# 95-gpu.rules
set_group_mode gpu 660 /dev/kgsl-3d0 /dev/ion /dev/dri/card* /dev/dri/controlD* /dev/dri/renderD*

# 96-i2c.rules
set_group_mode gpio 660 /dev/i2c-[0-9]*

# 98-panda.rules
set_usb_mode bbaa ddee 666
set_usb_mode bbaa ddcc 666
set_usb_mode 0483 df11 666
set_mode 666 /dev/spidev*

log "done"
