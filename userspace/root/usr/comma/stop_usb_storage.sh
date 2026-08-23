#!/bin/bash
set -euo pipefail

GADGET_HELPER="${USB_GADGET_HELPER:-/usr/comma/usb_gadget.sh}"
SLEEP_BIN="${USB_STORAGE_SLEEP_BIN:-sleep}"
STOP_ATTEMPTS="${USB_STORAGE_STOP_ATTEMPTS:-300}"
KILL_ATTEMPTS="${USB_STORAGE_KILL_ATTEMPTS:-20}"
POLL_INTERVAL="${USB_STORAGE_STOP_INTERVAL:-0.1}"

main_pid="${1:-}"
if [[ ! "$main_pid" =~ ^[1-9][0-9]*$ ]]; then
  echo "usage: $0 MAINPID" >&2
  "$GADGET_HELPER" unbind
  exit 2
fi
if [[ ! "$STOP_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] || [[ ! "$KILL_ATTEMPTS" =~ ^[1-9][0-9]*$ ]]; then
  echo "USB storage stop attempts must be positive integers" >&2
  "$GADGET_HELPER" unbind
  exit 2
fi

process_is_alive() {
  kill -0 "$main_pid" 2>/dev/null
}

# systemd runs ExecStop before applying KillSignal. Signal the manager first so
# graceful teardown observes stop_event and cannot choose to rebind. If it was
# already inside a rebind-capable teardown, wait for that operation to finish.
if process_is_alive; then
  kill -TERM "$main_pid" 2>/dev/null || true
fi
for ((attempt = 1; attempt <= STOP_ATTEMPTS; attempt++)); do
  process_is_alive || break
  "$SLEEP_BIN" "$POLL_INTERVAL"
done

if process_is_alive; then
  echo "USB storage manager did not stop gracefully; forcing main-process exit" >&2
  kill -KILL "$main_pid" 2>/dev/null || true
  for ((attempt = 1; attempt <= KILL_ATTEMPTS; attempt++)); do
    process_is_alive || break
    "$SLEEP_BIN" "$POLL_INTERVAL"
  done
fi

# This is deliberately last. A clean empty LUN keeps the other USB functions
# bound (and restores a fallback unbind); attached/unsafe media leaves the
# gadget disconnected before systemd kills the remaining FUSE/NBD cgroup.
"$GADGET_HELPER" finalize-storage-stop
