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
ADB_PARAM="${USB_GADGET_ADB_PARAM:-/data/params/d/AdbEnabled}"
# ADB-off is a distinct USB personality: mass storage at MI_00, without NCM or
# a disabled-placeholder interface.  It requires a product ID assigned by the
# VID owner so Windows cannot reuse the legacy 0x1234/MI_02 ADB driver binding.
# These intentionally have no production defaults until comma approves the
# identity; it may be allocated under comma's own VID or the legacy VID.
STORAGE_ONLY_VID="${USB_GADGET_STORAGE_ONLY_VID:-}"
STORAGE_ONLY_PID="${USB_GADGET_STORAGE_ONLY_PID:-}"

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

ensure_requested_personality() {
  local current_udc=""
  local adb_enabled=0

  current_udc="$(< "$GADGET_ROOT/UDC")"
  if [[ -n "$current_udc" ]]; then
    return 0
  fi
  if [[ -r "$ADB_PARAM" ]] && [[ "$(< "$ADB_PARAM")" == "1" ]]; then
    adb_enabled=1
  fi
  configure_gadget "$adb_enabled"
}

function_link_is_exact() {
  local name="$1"
  [[ -L "$CONFIG_ROOT/$name" ]] && [[ "$CONFIG_ROOT/$name" -ef "$FUNCTION_ROOT/$name" ]]
}

usb_id_is() {
  local actual="$1"
  local expected="$2"
  [[ "$actual" =~ ^0[xX][0-9a-fA-F]{4}$ ]] || return 1
  [[ "$expected" =~ ^0[xX][0-9a-fA-F]{4}$ ]] || return 1
  # Configfs canonicalizes hexadecimal attributes to lowercase on-device.
  # Compare validated numeric values so fake configfs and the kernel's
  # readback spelling are both accepted without weakening identity checks.
  ((actual == expected))
}

validate_single_configuration() {
  local entry
  local found_primary=0

  if [[ ! -d "$GADGET_ROOT/configs" ]] || [[ -L "$GADGET_ROOT/configs" ]]; then
    echo "USB gadget configurations directory is unavailable or unsafe" >&2
    return 1
  fi
  # Configfs may add regular attributes across kernel versions. They cannot
  # expose functions, so tolerate them. Every real child directory is a USB
  # configuration and every symlink is unexpected here; only c.1 is allowed.
  for entry in "$GADGET_ROOT/configs"/* "$GADGET_ROOT/configs"/.[!.]* "$GADGET_ROOT/configs"/..?*; do
    [[ -e "$entry" ]] || [[ -L "$entry" ]] || continue
    if [[ -L "$entry" ]]; then
      echo "refusing USB gadget with a linked configuration entry" >&2
      return 1
    elif [[ -d "$entry" ]]; then
      if [[ "$entry" != "$CONFIG_ROOT" ]]; then
        echo "refusing USB gadget with more than configuration c.1" >&2
        return 1
      fi
      found_primary=1
    elif [[ ! -f "$entry" ]]; then
      echo "refusing USB gadget with an unsafe configuration entry" >&2
      return 1
    fi
  done
  if ((!found_primary)); then
    echo "USB gadget configuration c.1 is unavailable" >&2
    return 1
  fi
}

validate_single_mass_storage_lun() {
  local entry
  local found_lun_zero=0
  local mass_storage_root="$FUNCTION_ROOT/mass_storage.0"

  if [[ ! -d "$mass_storage_root" ]] || [[ -L "$mass_storage_root" ]]; then
    echo "USB mass-storage function is unavailable or unsafe" >&2
    return 1
  fi
  # In this kernel every configfs child directory of a mass-storage function
  # is a dynamically created LUN (the group parser accepts NAME.NUMBER, not
  # only lun.NUMBER). Regular attributes such as stall and optional
  # num_buffers are harmless and must remain compatible across kernel builds.
  for entry in "$mass_storage_root"/* "$mass_storage_root"/.[!.]* "$mass_storage_root"/..?*; do
    [[ -e "$entry" ]] || [[ -L "$entry" ]] || continue
    if [[ -L "$entry" ]]; then
      echo "refusing USB mass storage with a linked function entry" >&2
      return 1
    elif [[ -d "$entry" ]]; then
      if [[ "$entry" != "$mass_storage_root/lun.0" ]]; then
        echo "refusing USB mass storage with more than LUN 0" >&2
        return 1
      fi
      found_lun_zero=1
    elif [[ ! -f "$entry" ]]; then
      echo "refusing USB mass storage with an unsafe function entry" >&2
      return 1
    fi
  done
  if ((!found_lun_zero)); then
    echo "USB mass-storage LUN 0 is unavailable" >&2
    return 1
  fi
}

validate_no_unowned_config_links() {
  local entry
  for entry in "$CONFIG_ROOT"/* "$CONFIG_ROOT"/.[!.]* "$CONFIG_ROOT"/..?*; do
    [[ -e "$entry" ]] || [[ -L "$entry" ]] || continue
    if [[ -L "$entry" ]]; then
      echo "refusing to configure USB with an unowned function link" >&2
      return 1
    fi
  done
}

validate_managed_storage_topology() {
  validate_single_configuration && validate_single_mass_storage_lun
}

validate_managed_storage_personality() {
  local adb_enabled=0
  local configured_function
  local expected_configuration="Storage"
  local expected_backing_file="$MANAGED_BACKING_FILE"
  local expected_product="$STORAGE_ONLY_PID"
  local expected_vendor="$STORAGE_ONLY_VID"

  if (($#)); then
    expected_backing_file="$1"
  fi
  if [[ -n "$expected_backing_file" && "$expected_backing_file" != "$MANAGED_BACKING_FILE" ]]; then
    echo "refusing invalid managed USB storage backing-file expectation" >&2
    return 1
  fi

  validate_managed_storage_topology || return 1

  if [[ -r "$ADB_PARAM" ]] && [[ "$(< "$ADB_PARAM")" == "1" ]]; then
    adb_enabled=1
    expected_configuration="NCM+ADB+Storage"
    expected_product="0x1234"
    expected_vendor="0x04D8"
  elif [[ ! "$STORAGE_ONLY_VID" =~ ^0[xX][0-9a-fA-F]{4}$ ]] || \
       [[ ! "$STORAGE_ONLY_PID" =~ ^0[xX][0-9a-fA-F]{4}$ ]] || \
       [[ "$STORAGE_ONLY_VID" =~ ^0[xX]04[dD]8$ && "$STORAGE_ONLY_PID" =~ ^0[xX]1234$ ]]; then
    echo "ADB-off storage requires a distinct owner-approved USB VID/PID" >&2
    return 1
  fi

  # Re-enumeration is deliberately narrower than configuration: it may only
  # bounce a complete personality whose sole storage backing is the manager's
  # generated image. It never repairs links, descriptors, or LUN policy and
  # therefore cannot raw-bind a partially configured gadget.
  if [[ ! -r "$GADGET_ROOT/idVendor" ]] || ! usb_id_is "$(< "$GADGET_ROOT/idVendor")" "$expected_vendor" || \
     [[ ! -r "$GADGET_ROOT/idProduct" ]] || ! usb_id_is "$(< "$GADGET_ROOT/idProduct")" "$expected_product" || \
     [[ ! -r "$CONFIG_ROOT/strings/0x409/configuration" ]] || \
     [[ "$(< "$CONFIG_ROOT/strings/0x409/configuration")" != "$expected_configuration" ]]; then
    echo "refusing to re-enumerate an unexpected USB personality" >&2
    return 1
  fi
  if [[ ! -r "$FUNCTION_ROOT/mass_storage.0/lun.0/file" ]] || \
     [[ ! -r "$FUNCTION_ROOT/mass_storage.0/lun.0/ro" ]] || \
     [[ ! -r "$FUNCTION_ROOT/mass_storage.0/lun.0/removable" ]] || \
     [[ ! -r "$FUNCTION_ROOT/mass_storage.0/stall" ]] || \
     [[ "$(< "$FUNCTION_ROOT/mass_storage.0/lun.0/file")" != "$expected_backing_file" ]] || \
     [[ "$(< "$FUNCTION_ROOT/mass_storage.0/lun.0/ro")" != "1" ]] || \
     [[ "$(< "$FUNCTION_ROOT/mass_storage.0/lun.0/removable")" != "1" ]] || \
     [[ "$(< "$FUNCTION_ROOT/mass_storage.0/stall")" != "1" ]] || \
     ! function_link_is_exact mass_storage.0; then
    echo "refusing to re-enumerate an unsafe or unmanaged USB storage LUN" >&2
    return 1
  fi

  if ((adb_enabled)); then
    if ! function_link_is_exact ncm.0 || ! function_link_is_exact ffs.adb; then
      echo "refusing to re-enumerate a partial ADB USB personality" >&2
      return 1
    fi
  elif [[ -L "$CONFIG_ROOT/ncm.0" ]] || [[ -L "$CONFIG_ROOT/ffs.adb" ]]; then
    echo "refusing to re-enumerate unexpected debug USB functions" >&2
    return 1
  fi

  # Reject every unrecognized function, including functions another process
  # may have added. Descriptor directories are not symbolic links.
  for configured_function in "$CONFIG_ROOT"/* "$CONFIG_ROOT"/.[!.]* "$CONFIG_ROOT"/..?*; do
    [[ -e "$configured_function" ]] || [[ -L "$configured_function" ]] || continue
    [[ -L "$configured_function" ]] || continue
    case "${configured_function##*/}" in
      mass_storage.0) ;;
      ncm.0|ffs.adb)
        if ((!adb_enabled)); then
          echo "refusing to re-enumerate unexpected debug USB functions" >&2
          return 1
        fi
        ;;
      *)
        echo "refusing to re-enumerate an unexpected USB function" >&2
        return 1
        ;;
    esac
  done
}

reenumerate_managed_storage() {
  local current_udc=""

  if [[ -r "$GADGET_ROOT/UDC" ]]; then
    current_udc="$(< "$GADGET_ROOT/UDC")"
  fi
  if [[ "$current_udc" != "$UDC_NAME" ]] || ! validate_managed_storage_personality; then
    unbind_gadget
    echo "USB storage re-enumeration validation failed; leaving gadget unbound" >&2
    return 1
  fi

  # Keep descriptors, function links, and the populated read-only LUN intact.
  # A full one-second disconnect makes hosts that stop polling an initially
  # empty removable LUN discover the newly inserted medium on the next bind.
  # From this point, every failure stays unbound.
  unbind_gadget
  "$SLEEP_BIN" 1
  if ! validate_managed_storage_personality; then
    unbind_gadget
    echo "USB storage changed during re-enumeration; leaving gadget unbound" >&2
    return 1
  fi
  current_udc="$(< "$GADGET_ROOT/UDC")"
  if [[ -n "$current_udc" ]]; then
    unbind_gadget
    echo "USB gadget rebound unexpectedly during storage re-enumeration" >&2
    return 1
  fi
  bind_gadget
}

prepare_storage_post_stop() {
  local lun_root="$FUNCTION_ROOT/mass_storage.0/lun.0"
  local backing_file=""

  # ExecStopPost runs after the service cgroup is dead. Validate the complete
  # LUN ownership boundary and accept only an empty LUN or this service's exact
  # backing path. Descriptor and function-link state is deliberately irrelevant
  # after unbinding: it must not prevent releasing a safe managed snapshot.
  # Foreign/unsafe media is preserved for diagnosis and left disconnected.
  if ! validate_managed_storage_topology || \
     [[ ! -f "$lun_root/file" ]] || [[ -L "$lun_root/file" ]] || \
     [[ ! -f "$lun_root/ro" ]] || [[ -L "$lun_root/ro" ]] || \
     [[ ! -f "$lun_root/removable" ]] || [[ -L "$lun_root/removable" ]] || \
     [[ ! -f "$FUNCTION_ROOT/mass_storage.0/stall" ]] || [[ -L "$FUNCTION_ROOT/mass_storage.0/stall" ]]; then
    unbind_gadget
    echo "USB storage post-stop LUN state is unavailable or unsafe; leaving gadget unbound" >&2
    return 1
  fi
  backing_file="$(< "$lun_root/file")"
  if [[ "$(< "$lun_root/ro")" != "1" ]] || [[ "$(< "$lun_root/removable")" != "1" ]] || \
     [[ "$(< "$FUNCTION_ROOT/mass_storage.0/stall")" != "1" ]]; then
    unbind_gadget
    echo "USB storage post-stop LUN policy is unsafe; leaving gadget unbound" >&2
    return 1
  fi
  if [[ -n "$backing_file" && "$backing_file" != "$MANAGED_BACKING_FILE" ]]; then
    unbind_gadget
    echo "refusing to clear a foreign USB mass-storage LUN after stop" >&2
    return 1
  fi

  if [[ -n "$backing_file" ]]; then
    unbind_gadget
    clear_lun_file "$lun_root/file"
  elif ! validate_managed_storage_personality ""; then
    # Preserve a zero-bounce clean stop only when the currently bound empty
    # personality is complete. Descriptor/link/PID drift must not block stale
    # snapshot cleanup, but it must be disconnected before cleanup and rebuilt
    # through the safe configuration path afterward.
    unbind_gadget
  fi
}

finalize_storage_stop() {
  local lun_root="$FUNCTION_ROOT/mass_storage.0/lun.0"
  local backing_file=""

  # The manager is already dead when this runs, so its configfs operations
  # cannot race this final decision. Preserve ADB/NCM after a clean stop, but
  # disconnect the whole gadget before systemd kills any backing processes if
  # media is still attached or the LUN policy cannot be verified.
  if [[ ! -r "$lun_root/file" || ! -r "$lun_root/ro" || ! -r "$lun_root/removable" ]]; then
    unbind_gadget
    echo "USB storage LUN state is unavailable; leaving gadget unbound" >&2
    return 1
  fi
  backing_file="$(< "$lun_root/file")"
  if [[ -n "$backing_file" ]] || [[ "$(< "$lun_root/ro")" != "1" ]] || [[ "$(< "$lun_root/removable")" != "1" ]]; then
    unbind_gadget
    if [[ -n "$backing_file" ]]; then
      echo "USB storage media remains attached; leaving gadget unbound" >&2
    else
      echo "USB storage LUN policy is unsafe; leaving gadget unbound" >&2
    fi
    return 0
  fi

  # A PREVENT-MEDIUM-REMOVAL fallback and a failed descriptor transition both
  # leave an empty UDC. Reconstruct the full requested personality instead of
  # blindly binding partial links/descriptors. This fails unbound when the
  # storage-only identity has not been approved.
  ensure_requested_personality
}

prepare_storage_start() {
  local lun_root="$FUNCTION_ROOT/mass_storage.0/lun.0"
  local backing_file=""

  # This runs before any stale FUSE recovery. Configfs must stop referencing
  # the old virtual disk first, or a lazy unmount could invalidate live host
  # I/O. Only this service's exact backing path may be released.
  if [[ ! -r "$lun_root/file" || ! -r "$lun_root/ro" || ! -r "$lun_root/removable" ]]; then
    unbind_gadget
    echo "USB storage LUN state is unavailable; leaving gadget unbound" >&2
    return 1
  fi
  backing_file="$(< "$lun_root/file")"
  if [[ "$(< "$lun_root/ro")" != "1" ]] || [[ "$(< "$lun_root/removable")" != "1" ]]; then
    unbind_gadget
    echo "USB storage LUN policy is unsafe; leaving gadget unbound" >&2
    return 1
  fi
  if [[ -n "$backing_file" && "$backing_file" != "$MANAGED_BACKING_FILE" ]]; then
    unbind_gadget
    echo "refusing to clear a foreign USB mass-storage LUN" >&2
    return 1
  fi
  if [[ -n "$backing_file" ]]; then
    unbind_gadget
    clear_lun_file "$lun_root/file" || return 1
  fi

  # A failed asynchronous personality transition and a legitimate fallback
  # unbind are indistinguishable here. Reconstruct the complete requested
  # personality instead of raw-binding potentially partial descriptors.
  ensure_requested_personality
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
    if write_attr "" "$file" 2>/dev/null && [[ "$(< "$file")" == "" ]]; then
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
  local vendor_id="0x04D8"
  local product_id="0x1234"

  RESTORE_BINDING=0
  RESTORE_HAD_ADB=0
  RESTORE_HAD_MASS_STORAGE=0
  RESTORE_HAD_NCM=0
  RESTORE_PREVIOUS_UDC=""

  if [[ "$adb_enabled" != "0" && "$adb_enabled" != "1" ]]; then
    echo "usage: $0 configure <0|1>" >&2
    return 2
  fi
  if [[ "$adb_enabled" == "0" ]]; then
    if [[ ! "$STORAGE_ONLY_VID" =~ ^0[xX][0-9a-fA-F]{4}$ ]] || \
       [[ ! "$STORAGE_ONLY_PID" =~ ^0[xX][0-9a-fA-F]{4}$ ]] || \
       [[ "$STORAGE_ONLY_VID" =~ ^0[xX]04[dD]8$ && "$STORAGE_ONLY_PID" =~ ^0[xX]1234$ ]]; then
      # AdbEnabled=0 must fail closed even before a storage-only identity is
      # allocated. Otherwise a previously bound debug personality and adbd
      # would remain reachable after the user disabled them.
      ensure_configfs
      unbind_gadget
      "$SYSTEMCTL_BIN" stop adbd
      echo "ADB-off storage requires a distinct owner-approved USB VID/PID" >&2
      return 1
    fi
    vendor_id="$STORAGE_ONLY_VID"
    product_id="$STORAGE_ONLY_PID"
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

  # Descriptor and daemon changes below cannot be safely rolled back from only
  # a link snapshot. Any later failure must therefore leave the gadget unbound
  # instead of mixing the old functions with a new VID/PID personality.
  RESTORE_BINDING=0

  # Never bind stale dynamic LUNs, alternate configurations, or unowned
  # function links. They may reference private or writable media. Preserve all
  # foreign state for diagnosis, but keep the UDC unbound and our links absent.
  if ! validate_managed_storage_topology || ! validate_no_unowned_config_links; then
    echo "refusing unsafe pre-existing USB gadget topology" >&2
    return 1
  fi

  write_attr "$vendor_id" "$GADGET_ROOT/idVendor"
  write_attr "$product_id" "$GADGET_ROOT/idProduct"
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
  fi
  write_attr "1" "$FUNCTION_ROOT/mass_storage.0/lun.0/ro"
  write_attr "1" "$FUNCTION_ROOT/mass_storage.0/lun.0/removable"
  write_attr "1" "$FUNCTION_ROOT/mass_storage.0/stall"

  if [[ "$adb_enabled" == "1" ]]; then
    # Keep the pre-existing NCM and ADB interface numbers stable for hosts that
    # cache composite-device bindings. Mass storage is appended as MI_03.
    link_function ncm.0
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
    write_attr "Storage" "$CONFIG_ROOT/strings/0x409/configuration"
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
  ensure-requested-personality)
    ensure_requested_personality
    ;;
  reenumerate-managed-storage)
    reenumerate_managed_storage
    ;;
  prepare-storage-post-stop)
    prepare_storage_post_stop
    ;;
  finalize-storage-stop)
    finalize_storage_stop
    ;;
  prepare-storage-start)
    prepare_storage_start
    ;;
  *)
    echo "usage: $0 {configure <0|1>|bind|unbind|ensure-requested-personality|reenumerate-managed-storage|prepare-storage-post-stop|finalize-storage-stop|prepare-storage-start}" >&2
    exit 2
    ;;
esac
