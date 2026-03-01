#!/bin/bash
# Void Linux version of set_adb.sh (based on userspace/usr/comma/set_adb.sh)
# Adds/removes ADB function from the existing USB gadget set up by the
# 9024 composition script at boot. Does NOT recreate the gadget.
# See set_adb_ncm.sh for version with USB networking.

GADGET=/sys/kernel/config/usb_gadget/g1

enable_adb() {
  cd $GADGET

  # Unbind gadget
  echo > UDC 2>/dev/null || true

  # Mount functionfs for ADB if needed
  mkdir -p /dev/usb-ffs/adb
  mountpoint -q /dev/usb-ffs/adb || mount -t functionfs adb /dev/usb-ffs/adb

  # Start adbd and wait for it to open ep0 (creates ep1/ep2)
  sv up adbd
  for i in $(seq 1 10); do
    [ -e /dev/usb-ffs/adb/ep1 ] && break
    sleep 0.5
  done

  # Add ADB function to gadget config
  ln -s functions/ffs.adb configs/c.1/ffs.adb 2>/dev/null || true

  # Rebind gadget
  echo a600000.dwc3 > UDC
}

disable_adb() {
  cd $GADGET

  # Unbind gadget
  echo > UDC 2>/dev/null || true

  # Remove ADB function, stop adbd
  rm -f configs/c.1/ffs.adb 2>/dev/null
  sv down adbd

  # Rebind gadget without ADB
  echo a600000.dwc3 > UDC 2>/dev/null || true
}

ADB_PARAM="/data/params/d/AdbEnabled"
if [ -f "$ADB_PARAM" ] && [ "$(< $ADB_PARAM)" == "1" ]; then
  echo "Enabling ADB"
  enable_adb
else
  echo "Disabling ADB"
  disable_adb
fi
