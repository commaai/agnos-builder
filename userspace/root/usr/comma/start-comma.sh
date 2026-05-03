#!/bin/bash

set -u

PATH=/usr/comma/shims:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

log() {
  local ts="?"
  if [ -r /proc/uptime ]; then
    ts="$(cut -d' ' -f1 /proc/uptime)"
  fi
  if [ -w /dev/kmsg ]; then
    printf '<6>start-comma[%d]: %s %s\n' "$$" "$ts" "$*" >/dev/kmsg 2>/dev/null || true
  fi
}

set_limits() {
  ulimit -Hr 100 2>/dev/null || true
  ulimit -Sr 100 2>/dev/null || true
  ulimit -He 30 2>/dev/null || true
  ulimit -Se 30 2>/dev/null || true
}

start_session() {
  local agnos_version

  agnos_version="$(cat /VERSION 2>/dev/null || true)"
  export AGNOS_VERSION="$agnos_version"
  export HOME=/home/comma
  export LOGNAME=comma
  export SHELL=/bin/bash
  export TERM=xterm-256color
  export USER=comma
  export XDG_RUNTIME_DIR=/var/tmp/xdg

  if /usr/bin/tmux has-session -t comma >/dev/null 2>&1; then
    log "tmux session already running"
    return 0
  fi

  /usr/bin/tmux new-session -s comma -d "/bin/bash -lc 'exec /bin/bash /usr/comma/comma.sh >>/tmp/comma.log 2>&1'"
  log "tmux session started"
}

monitor_session() {
  while /usr/bin/tmux has-session -t comma >/dev/null 2>&1; do
    sleep 5
  done
}

set_limits
if [ "$(id -u)" = "0" ]; then
  exec env \
    HOME=/home/comma \
    LOGNAME=comma \
    SHELL=/bin/bash \
    TERM=xterm-256color \
    USER=comma \
    XDG_RUNTIME_DIR=/var/tmp/xdg \
    PATH="$PATH" \
    setpriv --reuid=1000 --regid=1000 --init-groups "$0" "$@"
fi

start_session

if [ "${1:-}" = "--monitor" ]; then
  monitor_session
fi
