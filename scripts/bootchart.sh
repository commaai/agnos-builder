#!/usr/bin/env bash
set -e

ssh tici "systemd-analyze plot > /tmp/bootchart.svg"
scp tici:/tmp/bootchart.svg /tmp/bootchart.svg
google-chrome /tmp/bootchart.svg

