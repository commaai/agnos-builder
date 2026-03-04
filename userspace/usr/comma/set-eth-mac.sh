#!/bin/bash
set -e

IFACE="$1"
if [ -z "$IFACE" ]; then
  echo "Usage: $0 <interface>"
  exit 1
fi

SERIAL="$(cat /proc/cmdline | sed -e 's/^.*androidboot.serialno=//' -e 's/ .*$//')"
if [ -z "$SERIAL" ]; then
  echo "Could not read serial number from cmdline"
  exit 1
fi

# Hash the serial to generate a stable MAC address
HASH="$(echo -n "$SERIAL" | md5sum | cut -c1-12)"

# Build MAC with locally-administered, unicast prefix (02:xx:xx:xx:xx:xx)
MAC="$(printf '02:%s:%s:%s:%s:%s' "${HASH:0:2}" "${HASH:2:2}" "${HASH:4:2}" "${HASH:6:2}" "${HASH:8:2}")"

ip link set dev "$IFACE" address "$MAC"
echo "Set $IFACE MAC to $MAC (from serial $SERIAL)"
