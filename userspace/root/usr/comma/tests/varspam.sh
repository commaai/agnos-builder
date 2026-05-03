#!/bin/bash
set -e

RATE=${1:-1}

log_message() {
  # /var/log/syslog
  cat /usr/include/sqlite3.h | logger -t SPAM_TEST

  # /var/log/kern.log
  #cat /usr/include/sqlite3.h | sudo tee /dev/kmsg > /dev/null
}

# verify config is good
sudo logrotate -d /etc/logrotate.conf

sudo rm -rf /var/log/*
sudo sv restart /run/runit/services/rsyslog
sudo sv restart /run/runit/services/logrotate

while true; do
  for i in $(seq 1 $RATE); do
    log_message
  done

  echo
  df -h /var/
  sudo du -hs /var/log/* || true

  sleep 1
done
