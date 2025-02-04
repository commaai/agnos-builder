#!/bin/bash
set -e

RATE=${1:-1}

log_message() {
  # /var/log/syslog
  cat /usr/include/sqlite3.h | systemd-cat -t SPAM_TEST

  # /var/log/kern.log
  #cat /usr/include/sqlite3.h | sudo tee /dev/kmsg > /dev/null
}

# verify config is good
sudo logrotate -d /etc/logrotate.conf

sudo rm -rf /var/log/*
sudo systemctl daemon-reload
sudo systemctl restart rsyslog
sudo systemctl restart systemd-journald
sudo systemctl restart logrotate-hourly.timer

while true; do
  for i in $(seq 1 $RATE); do
    log_message
  done

  echo
  df -h /var/
  sudo du -hs /var/log/* || true

  sleep 1
done
