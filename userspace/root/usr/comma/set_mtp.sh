#!/bin/bash

setup() {
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
  echo 500 | sudo tee configs/c.1/MaxPower

  # Create MTP function
  sudo mkdir -p functions/ffs.mtp
  sudo mkdir -p /dev/usb-ffs/mtp
  if ! mountpoint -q /dev/usb-ffs/mtp; then
    sudo mount -t functionfs mtp /dev/usb-ffs/mtp
  else
    echo "/dev/usb-ffs/mtp is already mounted"
  fi

  # Link both functions into configuration
  echo "NCM+MTP" | sudo tee configs/c.1/strings/0x409/configuration
  sudo rm -f configs/c.1/ncm.0
  sudo rm -f configs/c.1/ffs.mtp
  sudo ln -s functions/ncm.0 configs/c.1/
  sudo ln -s functions/ffs.mtp configs/c.1/
}

start() {
  cd /config/usb_gadget/g1
  echo "a600000.dwc3" | sudo tee UDC
}

stop() {
  if [ -d "/config/usb_gadget/g1" ]; then
    cd /config/usb_gadget/g1
    echo "" | sudo tee UDC
  fi
}

setup
systemctl start umtprd
sleep 1

start
