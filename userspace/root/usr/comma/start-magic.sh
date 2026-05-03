#!/bin/bash

set -u

PATH=/usr/comma/shims:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
export HOME=/home/comma
export LOGNAME=comma
export SHELL=/bin/bash
export USER=comma
export XDG_RUNTIME_DIR=/var/tmp/xdg
export PYTHONPATH=/data/pythonpath
export UV_PYTHON_INSTALL_DIR=/usr/local/uv/python
export UV_PYTHON_PREFERENCE=only-system
export UV_LINK_MODE=copy

log() {
  local ts="?"
  if [ -r /proc/uptime ]; then
    ts="$(cut -d' ' -f1 /proc/uptime)"
  fi
  if [ -w /dev/kmsg ]; then
    printf '<6>start-magic[%d]: %s %s\n' "$$" "$ts" "$*" >/dev/kmsg 2>/dev/null || true
  fi
}

magic_running() {
  pgrep -u comma -f "/usr/comma/magic.py" >/dev/null 2>&1
}

prep_root() {
  chgrp gpu /dev/adsprpc-smd /dev/ion /dev/kgsl-3d0 /dev/dri/* 2>/dev/null || true
  chmod 660 /dev/adsprpc-smd /dev/kgsl-3d0 /dev/dri/* 2>/dev/null || true
  chmod 664 /dev/ion 2>/dev/null || true

  mkdir -p /data/misc/display /var/tmp/xdg
  (echo 0 >/data/misc/display/sdm_dbg_cfg.txt) 2>/dev/null || true
  (echo 0 >/data/misc/display/gbm_dbg_cfg.txt) 2>/dev/null || true
  chown comma:comma /var/tmp/xdg 2>/dev/null || true
}

prep_user() {
  mkdir -p /var/tmp/xdg 2>/dev/null || true
}

monitor_magic() {
  while magic_running; do
    sleep 5
  done
  log "magic exited"
  return 1
}

if [ "$(id -u)" = "0" ]; then
  prep_root
  exec env \
    HOME="$HOME" \
    LOGNAME="$LOGNAME" \
    SHELL="$SHELL" \
    USER="$USER" \
    XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
    PYTHONPATH="$PYTHONPATH" \
    UV_PYTHON_INSTALL_DIR="$UV_PYTHON_INSTALL_DIR" \
    UV_PYTHON_PREFERENCE="$UV_PYTHON_PREFERENCE" \
    UV_LINK_MODE="$UV_LINK_MODE" \
    PATH="$PATH" \
    setpriv --reuid=1000 --regid=1000 --init-groups "$0" "$@"
fi

prep_user

if magic_running; then
  log "magic already running"
  if [ "${1:-}" = "--monitor" ]; then
    monitor_magic
  fi
  exit 0
fi

log "exec magic"
exec /usr/local/venv/bin/python -u /usr/comma/magic.py
