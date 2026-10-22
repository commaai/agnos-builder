#!/bin/bash
set -euo pipefail

# qcom-firmware.service loads ADSP after the firmware partition is mounted.
for _ in $(seq 1 100); do
  [ -d /proc/asound/commamici ] && break
  sleep 0.1
done
test -d /proc/asound/commamici

# Q6 routing uses one frontend for each direction.
amixer -c commamici cset 'name=SEC_MI2S_RX Audio Mixer MultiMedia1' on > /dev/null
amixer -c commamici cset 'name=MultiMedia2 Mixer SEC_MI2S_TX' on > /dev/null
