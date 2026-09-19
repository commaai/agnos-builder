#!/bin/bash
set -e
cd /data/openpilot
source ./launch_env.sh
export PYTHONPATH=/data/openpilot
# This profile is for a fixed, built checkout with the matching manager adapter.
# Defer to the normal launcher for OS upgrades and pending checkout swaps.
[[ "$(< /VERSION)" == "$AGNOS_VERSION" ]] || exit 0
[[ ! -f "${STAGING_ROOT}/finalized/.overlay_consistent" ]] || exit 0
[[ ! -f /data/__system_reset__ ]] || exit 0
(( $(cat /sys/class/input/input2/device/touch_count) <= 4 )) || exit 0
echo $$ > /run/openpilot-ui/pid
exec /usr/local/venv/bin/python openpilot/selfdrive/ui/ui.py
