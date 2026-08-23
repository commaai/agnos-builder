#!/bin/bash
set -Eeuo pipefail

# Environment overrides make the configfs operations testable without a USB
# controller. Production callers use all of the defaults below.
CONFIGFS_ROOT="${USB_GADGET_CONFIGFS_ROOT:-/config}"
GADGET_NAME="${USB_GADGET_NAME:-g1}"
GADGET_ROOT="$CONFIGFS_ROOT/usb_gadget/$GADGET_NAME"
CONFIG_ROOT="$GADGET_ROOT/configs/c.1"
FUNCTION_ROOT="$GADGET_ROOT/functions"
FFS_ADB_ROOT="${USB_GADGET_FFS_ADB_ROOT:-/dev/usb-ffs/adb}"
LOCK_FILE="${USB_GADGET_LOCK_FILE:-/run/lock/comma-usb-gadget.lock}"
UDC_NAME="${USB_GADGET_UDC:-a600000.dwc3}"
MANAGED_BACKING_FILE="${USB_GADGET_MANAGED_BACKING_FILE:-/run/usb-storage/footage.img}"

MOUNTPOINT_BIN="${USB_GADGET_MOUNTPOINT_BIN:-mountpoint}"
MOUNT_BIN="${USB_GADGET_MOUNT_BIN:-mount}"
FLOCK_BIN="${USB_GADGET_FLOCK_BIN:-flock}"
SYSTEMCTL_BIN="${USB_GADGET_SYSTEMCTL_BIN:-systemctl}"
SETPROP_BIN="${USB_GADGET_SETPROP_BIN:-setprop}"
SLEEP_BIN="${USB_GADGET_SLEEP_BIN:-sleep}"
LN_BIN="${USB_GADGET_LN_BIN:-ln}"
SKIP_MOUNTS="${USB_GADGET_SKIP_MOUNTS:-0}"
CLEAR_ATTEMPTS="${USB_GADGET_CLEAR_ATTEMPTS:-50}"
CLEAR_INTERVAL="${USB_GADGET_CLEAR_INTERVAL:-0.1}"
RESTORE_BINDING=0
RESTORE_HAD_ADB=0
RESTORE_HAD_MASS_STORAGE=0
RESTORE_HAD_NCM=0
RESTORE_PREVIOUS_UDC=""

if [[ ! "$CLEAR_ATTEMPTS" =~ ^[1-9][0-9]*$ ]]; then
  echo "USB_GADGET_CLEAR_ATTEMPTS must be a positive integer" >&2
  exit 2
fi

write_attr() {
  local value="$1"
  local path="$2"
  printf '%s\n' "$value" > "$path"
}

ensure_configfs() {
  mkdir -p "$CONFIGFS_ROOT"
  if [[ "$SKIP_MOUNTS" != "1" ]] && ! "$MOUNTPOINT_BIN" -q "$CONFIGFS_ROOT"; then
    "$MOUNT_BIN" -t configfs none "$CONFIGFS_ROOT"
  fi
}

unbind_gadget() {
  local current_udc=""
  if [[ -r "$GADGET_ROOT/UDC" ]]; then
    current_udc="$(< "$GADGET_ROOT/UDC")"
  fi
  if [[ -n "$current_udc" ]]; then
    write_attr "" "$GADGET_ROOT/UDC"
  fi
}

bind_gadget() {
  local current_udc=""
  if [[ -r "$GADGET_ROOT/UDC" ]]; then
    current_udc="$(< "$GADGET_ROOT/UDC")"
  fi
  if [[ "$current_udc" == "$UDC_NAME" ]]; then
    return 0
  fi
  if [[ -n "$current_udc" ]]; then
    echo "USB gadget is already bound to $current_udc" >&2
    return 1
  fi
  write_attr "$UDC_NAME" "$GADGET_ROOT/UDC"
}

remove_owned_links() {
  local link
  for link in ncm.0 ffs.adb mass_storage.0; do
    if [[ -L "$CONFIG_ROOT/$link" ]]; then
      unlink "$CONFIG_ROOT/$link"
    fi
  done
}

link_function() {
  local name="$1"
  "$LN_BIN" -s "$FUNCTION_ROOT/$name" "$CONFIG_ROOT/$name"
}

restore_gadget_on_exit() {
  local status=$?
  trap - EXIT

  if ((RESTORE_BINDING)); then
    remove_owned_links || true
    if ((RESTORE_HAD_NCM)); then link_function ncm.0 || true; fi
    if ((RESTORE_HAD_ADB)); then link_function ffs.adb || true; fi
    if ((RESTORE_HAD_MASS_STORAGE)); then link_function mass_storage.0 || true; fi
    if [[ -n "$RESTORE_PREVIOUS_UDC" ]]; then
      write_attr "$RESTORE_PREVIOUS_UDC" "$GADGET_ROOT/UDC" || true
    fi
  fi
  exit "$status"
}

read_serial() {
  local serial="${USB_GADGET_SERIAL:-}"
  local cmdline="${USB_GADGET_CMDLINE:-/proc/cmdline}"

  if [[ -z "$serial" ]] && [[ -r "$cmdline" ]]; then
    serial="$(sed -n 's/.*androidboot.serialno=\([^ ]*\).*/\1/p' "$cmdline")"
  fi
  printf '%s' "${serial:-unknown}"
}

clear_lun_file() {
  local file="$1"
  local attempt

  for ((attempt = 1; attempt <= CLEAR_ATTEMPTS; attempt++)); do
    if write_attr "" "$file" 2>/dev/null; then
      return 0
    fi
    if ((attempt < CLEAR_ATTEMPTS)); then
      "$SLEEP_BIN" "$CLEAR_INTERVAL"
    fi
  done
  echo "timed out clearing USB mass-storage LUN after UDC unbind" >&2
  return 1
}

configure_gadget() {
  local adb_enabled="$1"
  local backing_file
  local mass_storage_created=0

  RESTORE_BINDING=0
  RESTORE_HAD_ADB=0
  RESTORE_HAD_MASS_STORAGE=0
  RESTORE_HAD_NCM=0
  RESTORE_PREVIOUS_UDC=""

  if [[ "$adb_enabled" != "0" && "$adb_enabled" != "1" ]]; then
    echo "usage: $0 configure <0|1>" >&2
    return 2
  fi

  ensure_configfs
  mkdir -p "$GADGET_ROOT"

  if [[ -r "$GADGET_ROOT/UDC" ]]; then
    RESTORE_PREVIOUS_UDC="$(< "$GADGET_ROOT/UDC")"
  fi
  if [[ -L "$CONFIG_ROOT/ncm.0" ]]; then RESTORE_HAD_NCM=1; fi
  if [[ -L "$CONFIG_ROOT/mass_storage.0" ]]; then RESTORE_HAD_MASS_STORAGE=1; fi
  if [[ -L "$CONFIG_ROOT/ffs.adb" ]]; then RESTORE_HAD_ADB=1; fi

  # USB gadget functions and links cannot be changed while the UDC is bound.
  # If setup fails partway through, restore the previous usable binding on a
  # best-effort basis rather than leaving USB disconnected.
  unbind_gadget
  RESTORE_BINDING=1
  trap restore_gadget_on_exit EXIT

  mkdir -p \
    "$GADGET_ROOT/strings/0x409" \
    "$CONFIG_ROOT/strings/0x409" \
    "$FUNCTION_ROOT/ncm.0"

  if [[ ! -d "$FUNCTION_ROOT/mass_storage.0" ]]; then
    mkdir -p "$FUNCTION_ROOT/mass_storage.0"
    mass_storage_created=1
  fi
  # lun.0 is created by configfs on-device; mkdir is also useful for a fake
  # configfs tree in tests.
  mkdir -p "$FUNCTION_ROOT/mass_storage.0/lun.0"

  # Function attributes must be changed while the function is unlinked as well
  # as while the UDC is unbound (stall returns EBUSY once linked).
  remove_owned_links

  write_attr "0x04D8" "$GADGET_ROOT/idVendor"
  write_attr "0x1234" "$GADGET_ROOT/idProduct"
  write_attr "$(read_serial)" "$GADGET_ROOT/strings/0x409/serialnumber"
  write_attr "comma.ai" "$GADGET_ROOT/strings/0x409/manufacturer"
  write_attr "Linux USB Gadget" "$GADGET_ROOT/strings/0x409/product"
  write_attr "250" "$CONFIG_ROOT/MaxPower"

  # Hosts must never receive /data or another live filesystem. Every gadget
  # reconfiguration ejects stale media before relinking; the manager may later
  # hot-insert only its generated image into this removable, read-only LUN.
  if ((mass_storage_created)) || [[ ! -e "$FUNCTION_ROOT/mass_storage.0/lun.0/file" ]]; then
    : > "$FUNCTION_ROOT/mass_storage.0/lun.0/file"
  fi
  backing_file="$(< "$FUNCTION_ROOT/mass_storage.0/lun.0/file")"
  if [[ -n "$backing_file" ]]; then
    # From this point until the stale media is gone, any error must leave the
    # UDC unbound. Rebinding a dead FUSE target or unsafe LUN is never valid.
    RESTORE_BINDING=0
    if [[ "$backing_file" != "$MANAGED_BACKING_FILE" ]]; then
      echo "refusing to clear a foreign USB mass-storage LUN" >&2
      exit 1
    fi
    if [[ "$(< "$FUNCTION_ROOT/mass_storage.0/lun.0/ro")" != "1" ]] || \
       [[ "$(< "$FUNCTION_ROOT/mass_storage.0/lun.0/removable")" != "1" ]]; then
      echo "refusing to reconfigure an attached writable or fixed USB LUN" >&2
      exit 1
    fi
    if ! clear_lun_file "$FUNCTION_ROOT/mass_storage.0/lun.0/file"; then
      exit 1
    fi
    RESTORE_BINDING=1
  fi
  write_attr "1" "$FUNCTION_ROOT/mass_storage.0/lun.0/ro"
  write_attr "1" "$FUNCTION_ROOT/mass_storage.0/lun.0/removable"
  write_attr "1" "$FUNCTION_ROOT/mass_storage.0/stall"

  # Keep the pre-existing NCM and ADB interface numbers stable for hosts that
  # cache composite-device bindings. Mass storage is always appended last.
  link_function ncm.0

  if [[ "$adb_enabled" == "1" ]]; then
    mkdir -p "$FUNCTION_ROOT/ffs.adb" "$FFS_ADB_ROOT"
    if [[ "$SKIP_MOUNTS" != "1" ]] && ! "$MOUNTPOINT_BIN" -q "$FFS_ADB_ROOT"; then
      "$MOUNT_BIN" -t functionfs adb "$FFS_ADB_ROOT"
    fi

    "$SETPROP_BIN" service.adb.tcp.port -1
    "$SYSTEMCTL_BIN" start adbd
    "$SLEEP_BIN" 1  # adbd must open FunctionFS endpoints before UDC binding
    link_function ffs.adb
  fi

  link_function mass_storage.0
  if [[ "$adb_enabled" == "1" ]]; then
    write_attr "NCM+ADB+Storage" "$CONFIG_ROOT/strings/0x409/configuration"
  else
    "$SYSTEMCTL_BIN" stop adbd
    write_attr "NCM+Storage" "$CONFIG_ROOT/strings/0x409/configuration"
  fi

  bind_gadget
  RESTORE_BINDING=0
  trap - EXIT
}

mkdir -p "$(dirname "$LOCK_FILE")"
if [[ -L "$LOCK_FILE" ]]; then
  echo "refusing symbolic-link USB gadget lock" >&2
  exit 1
fi
if [[ ! -e "$LOCK_FILE" ]]; then
  # noclobber makes first creation exclusive. Production pre-creates this
  # root-owned file through tmpfiles before less-trusted services start.
  if ! (umask 077; set -o noclobber; : > "$LOCK_FILE") 2>/dev/null; then
    echo "failed safely creating USB gadget lock" >&2
    exit 1
  fi
fi
if [[ ! -f "$LOCK_FILE" ]] || [[ -L "$LOCK_FILE" ]]; then
  echo "USB gadget lock is not a regular file" >&2
  exit 1
fi
# Open without truncation. The root-owned file cannot be replaced by an
# unprivileged process in the sticky /run/lock directory.
exec 9<> "$LOCK_FILE"
"$FLOCK_BIN" -x 9

case "${1:-}" in
  configure)
    configure_gadget "${2:-}"
    ;;
  bind)
    bind_gadget
    ;;
  unbind)
    unbind_gadget
    ;;
  *)
    echo "usage: $0 {configure <0|1>|bind|unbind}" >&2
    exit 2
    ;;
esac
