#!/bin/bash
set -euo pipefail

ADB_PARAM="${USB_GADGET_ADB_PARAM:-/data/params/d/AdbEnabled}"
GADGET_HELPER="${USB_GADGET_HELPER:-$(dirname "${BASH_SOURCE[0]}")/usb_gadget.sh}"

adb_enabled=0
if [[ -r "$ADB_PARAM" ]] && [[ "$(< "$ADB_PARAM")" == "1" ]]; then
  adb_enabled=1
  echo "Enabling ADB"
else
  echo "Disabling ADB"
fi

# usb_gadget.sh is the sole owner of configfs setup. NCM and read-only storage
# remain available regardless of the ADB param; only FunctionFS ADB is gated.
exec "$GADGET_HELPER" configure "$adb_enabled"
