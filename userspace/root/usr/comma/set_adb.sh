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

# usb_gadget.sh is the sole owner of configfs setup. The ADB personality keeps
# its legacy NCM and FunctionFS interfaces; ADB-off exposes storage only under
# a distinct owner-approved USB identity.
exec "$GADGET_HELPER" configure "$adb_enabled"
