#!/bin/bash

/usr/comma/sound/adsp-start.sh

echo "waiting for sound card to come online"
while [ ! -d /proc/asound/sdm845tavilsndc ] || [ "$(cat /proc/asound/card0/state 2> /dev/null)" != "ONLINE" ] ; do
  sleep 0.01
done
echo "sound card online"

while ! amixer -D hw:0 controls | grep -q "SEC_MI2S_RX Audio Mixer MultiMedia1"; do
  sleep 0.01
done
echo "mixer controls ready"

amixer -D hw:0 -q cset "name='SEC_MI2S_RX Audio Mixer MultiMedia1'" 1
if grep -q mici /sys/firmware/devicetree/base/model; then
  amixer -D hw:0 -q cset "name='MultiMedia1 Mixer SEC_MI2S_TX'" 1
else
  amixer -D hw:0 -q cset "name='MultiMedia1 Mixer TERT_MI2S_TX'" 1
  amixer -D hw:0 -q cset "name='TERT_MI2S_TX Channels'" Two
fi

# setup the amplifier registers
/usr/local/venv/bin/python /usr/comma/sound/amplifier.py
