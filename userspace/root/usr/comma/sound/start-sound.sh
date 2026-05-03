#!/bin/bash

set -u

BOOTSH_RUN=/run/bootsh

if [ "${1:-}" = "--boot" ]; then
  mkdir -p "$BOOTSH_RUN"
  rm -f "$BOOTSH_RUN/sound-ready" "$BOOTSH_RUN/sound-failed"
  touch "$BOOTSH_RUN/sound-started"

  if /usr/comma/sound/sound_init.sh; then
    touch "$BOOTSH_RUN/sound-ready"
    exit 0
  fi

  touch "$BOOTSH_RUN/sound-failed"
  exit 1
fi

if [ -e "$BOOTSH_RUN/sound-started" ]; then
  while pgrep -f "/usr/comma/sound/sound_init.sh" >/dev/null 2>&1; do
    sleep 0.1
  done

  [ -e "$BOOTSH_RUN/sound-ready" ] && exit 0
  exit 1
fi

exec /usr/comma/sound/sound_init.sh
