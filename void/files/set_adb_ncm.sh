#!/bin/bash
# USB gadget setup with both ADB and NCM (USB networking).
# Use this for development when WiFi isn't available.
# Production uses set_adb.sh (ADB only, no USB networking).
#
# Reconfigures the existing gadget set up by the 9024 composition script.
# Requires: adbd service, 9024 already ran at boot.

GADGET=/sys/kernel/config/usb_gadget/g1

enable_adb() {
  cd $GADGET

  # Unbind gadget
  echo > UDC

  # Mount functionfs for ADB if needed
  mkdir -p /dev/usb-ffs/adb
  if ! mountpoint -q /dev/usb-ffs/adb; then
    mount -t functionfs adb /dev/usb-ffs/adb
  fi

  # Start adbd so it opens ep0
  sv up adbd
  sleep 1

  # Link ADB function (configfs needs relative symlinks)
  ln -s functions/ffs.adb configs/c.1/f2 2>/dev/null || true

  # Rebind gadget
  echo a600000.dwc3 > UDC

  # Restore USB networking (usb0 takes a moment to appear after UDC binding)
  sleep 2
  ip addr add 192.168.7.1/24 dev usb0 2>/dev/null || true
  ip link set usb0 up
}

disable_adb() {
  cd $GADGET

  # Unbind gadget
  echo > UDC

  # Remove ADB function link
  rm -f configs/c.1/f2

  # Stop adbd
  sv down adbd

  # Rebind gadget (NCM only)
  echo a600000.dwc3 > UDC

  # Restore USB networking
  sleep 2
  ip addr add 192.168.7.1/24 dev usb0 2>/dev/null || true
  ip link set usb0 up
}

ADB_PARAM="/data/params/d/AdbEnabled"
if [ -f "$ADB_PARAM" ] && [ "$(< $ADB_PARAM)" == "1" ]; then
  echo "Enabling ADB"
  enable_adb
else
  echo "Disabling ADB"
  disable_adb
fi
