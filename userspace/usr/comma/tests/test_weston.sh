#!/usr/bin/bash
set -e

sleep 10

for i in {1..25}; do
  echo "waiting for weston: ${i}s"
  if [ -e "$XDG_RUNTIME_DIR/wayland-0" ]; then
    break
  fi
  sleep 1
done

sleep 10

SOCKET="false"
if [ -e "$XDG_RUNTIME_DIR/wayland-0" ]; then
  SOCKET="true"
fi

echo "weston: is_active=$(systemctl is-active weston), socket=$SOCKET" >> /data/weston_log
sync
sudo reboot
