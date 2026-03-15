#!/bin/bash

/usr/comma/sound/adsp-start.sh

echo "waiting for sound card to come online"
while [ ! -f /proc/asound/card0/state ] || [ "$(cat /proc/asound/card0/state 2> /dev/null)" != "ONLINE" ] ; do
  sleep 0.01
done
echo "sound card online"

find_control() {
  local control

  for control in "$@"; do
    if /usr/comma/sound/tinymix controls | grep -F -q "$control"; then
      echo "$control"
      return 0
    fi
  done

  return 1
}

if grep -q mici /sys/firmware/devicetree/base/model; then
  CAPTURE_CANDIDATES=("Comma Audio Mixer SEC_MI2S_TX" "MultiMedia1 Mixer SEC_MI2S_TX")
else
  CAPTURE_CANDIDATES=("Comma Audio Mixer TERT_MI2S_TX" "MultiMedia1 Mixer TERT_MI2S_TX")
fi

PLAYBACK_CANDIDATES=("SEC_MI2S_RX Audio Mixer Comma Audio" "SEC_MI2S_RX Audio Mixer MultiMedia1")

while true; do
  PLAYBACK_CONTROL=$(find_control "${PLAYBACK_CANDIDATES[@]}")
  CAPTURE_CONTROL=$(find_control "${CAPTURE_CANDIDATES[@]}")
  if [ -n "$PLAYBACK_CONTROL" ] && [ -n "$CAPTURE_CONTROL" ]; then
    break
  fi
  sleep 0.01
done
echo "tinymix controls ready"

/usr/comma/sound/tinymix set "$PLAYBACK_CONTROL" 1
/usr/comma/sound/tinymix set "$CAPTURE_CONTROL" 1
if /usr/comma/sound/tinymix controls | grep -F -q "TERT_MI2S_TX Channels"; then
  /usr/comma/sound/tinymix set "TERT_MI2S_TX Channels" Two
fi

# setup the amplifier registers
/usr/local/venv/bin/python /usr/comma/sound/amplifier.py
