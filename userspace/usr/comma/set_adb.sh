#!/bin/bash

setup_gadget() {
  # Check if /config is already mounted
  if ! mountpoint -q /config; then
    sudo mount -t configfs none /config
  else
    echo "/config is already mounted."
  fi

  # Create USB gadget directory structure
  sudo mkdir -p /config/usb_gadget/g1
  cd /config/usb_gadget/g1
  sudo mkdir -p strings/0x409
  sudo mkdir -p configs/c.1/strings/0x409
  sudo mkdir -p functions/ncm.0

  # Set Vendor and Product ID
  echo 0x04D8 | sudo tee idVendor
  echo 0x1234 | sudo tee idProduct

  # Set strings
  echo "$(cat /proc/cmdline | sed -e 's/^.*androidboot.serialno=//' -e 's/ .*$//')" | sudo tee strings/0x409/serialnumber
  echo "comma.ai" | sudo tee strings/0x409/manufacturer
  echo "Linux USB Gadget" | sudo tee strings/0x409/product
  echo 250 | sudo tee configs/c.1/MaxPower

  # Create ADB function
  sudo mkdir -p functions/ffs.adb
  sudo mkdir -p /dev/usb-ffs/adb
  if ! mountpoint -q /dev/usb-ffs/adb; then
    sudo mount -t functionfs adb /dev/usb-ffs/adb
  else
    echo "/dev/usb-ffs/adb is already mounted"
  fi
  # Link both functions to configuration
  echo "NCM+ADB" | sudo tee configs/c.1/strings/0x409/configuration
  sudo rm -f configs/c.1/ncm.0
  sudo rm -f configs/c.1/ffs.adb
  sudo ln -s functions/ncm.0 configs/c.1/
  sudo ln -s functions/ffs.adb configs/c.1/
}

start_gadget() {
  cd /config/usb_gadget/g1
  echo "a600000.dwc3" | sudo tee UDC
}

stop_gadget() {
  if [ -d "/config/usb_gadget/g1" ]; then
    cd /config/usb_gadget/g1
    echo "" | sudo tee UDC
  fi
}

ADB_PARAM="/data/params/d/AdbEnabled"
if [ -f "$ADB_PARAM" ] && [ "$(< $ADB_PARAM)" == "1" ]; then
  echo "Enabling ADB"

  setup_gadget
  systemctl start adbd
  sleep 1
  start_gadget
else
  echo "Disabling ADB"
  systemctl stop adbd
  stop_gadget
fi
