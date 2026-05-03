#!/usr/bin/env bash
set -e

ssh tici "dmesg | grep 'boot.sh' > /tmp/bootchart.txt"
scp tici:/tmp/bootchart.txt /tmp/bootchart.txt
cat /tmp/bootchart.txt
