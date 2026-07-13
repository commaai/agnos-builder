#!/bin/bash

setup() {
  cd /config/usb_gadget/g1

  # Create ADB function
  sudo mkdir -p functions/ffs.adb
  sudo mkdir -p /dev/usb-ffs/adb
  if ! mountpoint -q /dev/usb-ffs/adb; then
    sudo mount -t functionfs adb /dev/usb-ffs/adb
  else
    echo "/dev/usb-ffs/adb is already mounted"
  fi

  # Link ADB functions to configuration
  sudo ln -s functions/ffs.adb configs/c.1/
}

start() {
  setprop service.adb.tcp.port -1

  cd /config/usb_gadget/g1
  echo "" | sudo tee UDC
  echo "a600000.dwc3" | sudo tee UDC
}

stop() {
  if [ -d "/config/usb_gadget/g1" ]; then
    cd /config/usb_gadget/g1
    echo "" | sudo tee UDC
    sudo rm -f configs/c.1/ffs.adb
    echo "a600000.dwc3" | sudo tee UDC
  fi
}

ADB_PARAM="/data/params/d/AdbEnabled"
if [ -f "$ADB_PARAM" ] && [ "$(< $ADB_PARAM)" == "1" ]; then
  echo "Enabling ADB"

  setup
  systemctl start adbd
  sleep 1  # adbd does some setup before we can enable the gadget
  start
else
  echo "Disabling ADB"

  systemctl stop adbd
  stop
fi
