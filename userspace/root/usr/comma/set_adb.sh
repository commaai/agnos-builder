#!/bin/bash
set -e

GADGET=/config/usb_gadget/g1

setup() {
  if ! mountpoint -q /config; then
    sudo mount -t configfs none /config
  else
    echo "/config is already mounted."
  fi

  sudo mkdir -p "$GADGET"
  cd "$GADGET"
  sudo mkdir -p strings/0x409
  sudo mkdir -p configs/c.1/strings/0x409
}

setup_adb() {
  setup
  sudo mkdir -p functions/ncm.0

  echo 0x04D8 | sudo tee idVendor
  echo 0x1234 | sudo tee idProduct

  sed -e 's/^.*androidboot.serialno=//' -e 's/ .*$//' /proc/cmdline | sudo tee strings/0x409/serialnumber
  echo "comma.ai" | sudo tee strings/0x409/manufacturer
  echo "Linux USB Gadget" | sudo tee strings/0x409/product
  echo 250 | sudo tee configs/c.1/MaxPower

  sudo mkdir -p functions/ffs.adb
  sudo mkdir -p /dev/usb-ffs/adb
  if ! mountpoint -q /dev/usb-ffs/adb; then
    sudo mount -t functionfs adb /dev/usb-ffs/adb
  else
    echo "/dev/usb-ffs/adb is already mounted"
  fi

  echo "NCM+ADB" | sudo tee configs/c.1/strings/0x409/configuration
  sudo rm -f configs/c.1/ncm.0
  sudo rm -f configs/c.1/ffs.adb
  sudo rm -f configs/c.1/mass_storage.0
  sudo ln -s functions/ncm.0 configs/c.1/
  sudo ln -s functions/ffs.adb configs/c.1/
}

setup_storage() {
  setup
  sudo mkdir -p functions/mass_storage.0

  # Reuse the existing AGNOS identity with a separate storage instance.
  echo 0x04D8 | sudo tee idVendor
  echo 0x1234 | sudo tee idProduct
  sed -e 's/^.*androidboot.serialno=//' -e 's/ .*$//' -e 's/$/-storage/' /proc/cmdline | sudo tee strings/0x409/serialnumber
  echo "comma.ai" | sudo tee strings/0x409/manufacturer
  echo "comma.ai Footage" | sudo tee strings/0x409/product
  echo 250 | sudo tee configs/c.1/MaxPower
  echo "Read-only footage" | sudo tee configs/c.1/strings/0x409/configuration

  sudo rm -f configs/c.1/ncm.0
  sudo rm -f configs/c.1/ffs.adb
  sudo rm -f configs/c.1/mass_storage.0
  echo 1 | sudo tee functions/mass_storage.0/lun.0/ro
  echo 1 | sudo tee functions/mass_storage.0/lun.0/removable
  echo 1 | sudo tee functions/mass_storage.0/stall
  printf '%-8s%-16s%-4s' 'comma.ai' 'footage' '1.0' |
    sudo tee functions/mass_storage.0/lun.0/inquiry_string > /dev/null
  sudo ln -s functions/mass_storage.0 configs/c.1/
}

start() {
  cd "$GADGET"
  echo "a600000.dwc3" | sudo tee UDC
}

clear_storage() {
  local file="$GADGET/functions/mass_storage.0/lun.0/file"
  [ -r "$file" ] || return 0
  [ -n "$(< "$file")" ] || return 0
  for _ in {1..50}; do
    echo "" | sudo tee "$file" > /dev/null 2>&1 || true
    [ -z "$(< "$file")" ] && return
    sleep 0.1
  done
  return 1
}

stop() {
  if [ -d "$GADGET" ]; then
    cd "$GADGET"
    if [ -r UDC ] && [ -n "$(< UDC)" ]; then
      echo "" | sudo tee UDC
    fi
    clear_storage
  fi
}

ADB_PARAM="/data/params/d/AdbEnabled"
systemctl stop usb-storage.service
exec 9>/run/comma-usb-gadget.lock
flock 9
stop

if [ -f "$ADB_PARAM" ] && [ "$(< "$ADB_PARAM")" == "1" ]; then
  echo "Enabling ADB"

  setup_adb
  systemctl start adbd
  sleep 1  # adbd does some setup before we can enable the gadget
  setprop service.adb.tcp.port -1
  start
else
  echo "Disabling ADB"

  setup_storage
  systemctl stop adbd
  start
  flock -u 9
  systemctl start --no-block usb-storage.service
fi
