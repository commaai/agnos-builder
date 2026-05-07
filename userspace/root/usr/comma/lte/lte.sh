#!/bin/bash

function gpio {
  echo "out" > /sys/class/gpio/gpio$1/direction
  echo $2 > /sys/class/gpio/gpio$1/value
}

LTE_RST_N=50
LTE_BOOT=52
LTE_PWRKEY=116

function is_modem_up {
  if lsusb -d "0x05c6:" >/dev/null 2>&1 || lsusb -d "0x2c7c:" >/dev/null 2>&1; then
    return 0
  else
    return 1
  fi
}

function is_modem_sysfs {
  local path="$1"
  local parent vendor product

  parent="$(realpath "$path")"
  while [[ -n "$parent" && "$parent" != "/" ]]; do
    if [[ -r "$parent/idVendor" && -r "$parent/idProduct" ]]; then
      read -r vendor < "$parent/idVendor"
      read -r product < "$parent/idProduct"
      [[ "$vendor" == "2c7c" || "$vendor:$product" == "05c6:9330" ]]
      return
    fi
    parent="${parent%/*}"
  done

  return 1
}

function setup_modem_ttys {
  local path name iface found i

  for i in {0..300}; do
    found=0
    for path in /sys/class/tty/ttyUSB* /sys/class/tty/ttyACM*; do
      [[ -e "$path" ]] || continue
      is_modem_sysfs "$path" || continue

      name="${path##*/}"
      [[ -c "/dev/$name" ]] || continue
      chgrp dialout "/dev/$name"
      chmod 0660 "/dev/$name"
      found=1

      iface="$(realpath "$path")"
      while [[ "$iface" != "/" && ! -r "$iface/bInterfaceNumber" ]]; do
        iface="${iface%/*}"
      done

      [[ -r "$iface/bInterfaceNumber" && -r "${iface%/*}/idVendor" ]] || continue
      [[ "$(< "${iface%/*}/idVendor")" == "2c7c" ]] || continue
      case "$(< "$iface/bInterfaceNumber")" in
        02) ln -sfn "/dev/$name" /dev/modem_at0 ;;
        03) ln -sfn "/dev/$name" /dev/modem_at1 ;;
      esac
    done

    ((found)) && return
    sleep 0.01
  done
}

function report_modem_kernel_events {
  local path name subsystem

  for path in /sys/class/tty/ttyUSB* /sys/class/tty/ttyACM* /sys/class/usbmisc/cdc-wdm* /sys/class/net/*; do
    [[ -e "$path" ]] || continue
    is_modem_sysfs "$path" || continue

    name="${path##*/}"
    subsystem="${path%/*}"
    subsystem="${subsystem##*/}"
    mmcli --report-kernel-event="action=add,subsystem=$subsystem,name=$name"
  done
}

function reset {
  echo " Resetting..."
  gpio $LTE_RST_N 1
  sleep 1
  gpio $LTE_RST_N 0
}

function power_button {
  echo " Pulsing power button..."
  gpio $LTE_PWRKEY 1
  sleep 1
  gpio $LTE_PWRKEY 0
}

function is_online {
  echo " Waiting until the modem comes online..."

  for i in {0..30}; do
    if is_modem_up; then
      echo "  Modem is online!"
      return 0
    fi

    echo "  Waiting..."
    sleep 1
  done

  return 1
}

function is_offline {
  echo " Waiting until the modem goes offline..."

  for i in {0..30}; do
    if ! is_modem_up; then
      echo "  Modem is offline!"
      return 0
    fi

    echo "  Waiting..."
    sleep 1
  done

  return 1
}

# Boot into the regular mode
gpio $LTE_BOOT 0

case "$1" in
  start)
    echo "Starting LTE..."

    reset
    power_button
    until is_online; do
      reset
      power_button
    done
    setup_modem_ttys
    report_modem_kernel_events

    ;;
  stop)
    echo "Stopping LTE..."

    if is_online; then
      power_button
    fi

    ;;
  stop_blocking)
    echo "Stopping LTE..."

    if is_online; then
      power_button
    fi

    until is_offline; do
      power_button
    done

    ;;
  *)
    echo "Specify either start or stop as first argument!"
    exit 1
    ;;
esac
