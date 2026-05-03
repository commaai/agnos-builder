#!/bin/bash

PATH=/usr/comma/shims:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

log() {
  local name ts
  name="${SVDIR##*/}"
  [ -n "$name" ] || name="${0##*/}"
  ts="?"
  [ -r /proc/uptime ] && ts="$(cut -d' ' -f1 /proc/uptime)"
  printf '<6>runit-%s[%d]: %s %s\n' "$name" "$$" "$ts" "$*" >/dev/kmsg 2>/dev/null || true
  printf 'runit-%s[%d]: %s %s\n' "$name" "$$" "$ts" "$*"
}

wait_path() {
  local path="$1"
  local i
  for i in $(seq 1 300); do
    [ -e "$path" ] && return 0
    sleep 0.1
  done
  log "timeout waiting for $path"
  return 1
}

wait_dbus() {
  wait_path /run/dbus/system_bus_socket
}

param_enabled() {
  local path="$1"
  [ -f "$path" ] && [ "$(cat "$path" 2>/dev/null)" = "1" ]
}

run_as_comma() {
  exec env \
    HOME=/home/comma \
    LOGNAME=comma \
    SHELL=/bin/bash \
    TERM=xterm-256color \
    USER=comma \
    XDG_RUNTIME_DIR=/var/tmp/xdg \
    PATH="$PATH" \
    setpriv --reuid=1000 --regid=1000 --init-groups "$@"
}
