#!/bin/bash
set -euo pipefail

GADGET_HELPER="${USB_GADGET_HELPER:-/usr/comma/usb_gadget.sh}"
CLEANUP_BIN="${USB_STORAGE_CLEANUP_BIN:-/usr/comma/cleanup_usb_storage.py}"

fail_unbound() {
  "$GADGET_HELPER" unbind >/dev/null 2>&1 || true
}

# ExecStopPost runs after systemd has killed the service cgroup, so nbdfuse and
# nbdkit can no longer race this recovery. Release only our validated LUN
# before detaching FUSE or dropping the snapshot's hard links.
if ! "$GADGET_HELPER" prepare-storage-post-stop; then
  fail_unbound
  exit 1
fi
if ! "$CLEANUP_BIN"; then
  fail_unbound
  exit 1
fi

# A forced stop leaves the gadget unbound while cleanup runs. Reconstruct the
# complete requested personality; never raw-bind potentially partial state.
if ! "$GADGET_HELPER" ensure-requested-personality; then
  fail_unbound
  exit 1
fi
