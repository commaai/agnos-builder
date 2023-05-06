#!/usr/bin/bash
set -e

sudo systemctl daemon-reload
sudo systemctl stop weston
sudo systemctl restart weston
sleep 2
sudo systemctl restart weston-ready
journalctl -u weston -f
