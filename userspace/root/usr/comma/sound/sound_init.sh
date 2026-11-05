#!/bin/bash
set -euo pipefail

case "$(tr -d '\0' < /proc/device-tree/model)" in
  "comma mici") card=commamici; capture=SEC_MI2S_TX ;;
  "comma tizi") card=commatizi; capture=TERT_MI2S_TX ;;
  *) echo "unknown device" >&2; exit 1 ;;
esac

# qcom-firmware.service boots the ADSP, which brings up the card
echo "waiting for sound card to come online"
for _ in $(seq 100); do
  [ -d "/proc/asound/$card" ] && break
  sleep 0.1
done
test -d "/proc/asound/$card"
echo "sound card online"

# playback is MultiMedia1 (device 0), capture is MultiMedia2 (device 1)
amixer -c "$card" -q cset "name='SEC_MI2S_RX Audio Mixer MultiMedia1'" 1
amixer -c "$card" -q cset "name='MultiMedia2 Mixer $capture'" 1

# setup the amplifier registers
/usr/local/venv/bin/python /usr/comma/sound/amplifier.py
