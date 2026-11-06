#!/bin/bash

# wait for the firmware partition
for _ in {1..100}; do
  [ -s /firmware/image/adsp.mdt ] && break
  sleep 0.1
done
[ -s /firmware/image/adsp.mdt ] || { echo "adsp firmware not found"; exit 1; }

adsp=$(grep -lx adsp /sys/bus/msm_subsys/devices/*/name)
[ -n "$adsp" ] || { echo "adsp subsystem not found"; exit 1; }
state=$(dirname "$adsp")/state

# TODO: is this needed?
echo 1 > /sys/module/subsystem_restart/parameters/enable_debug

echo "bringing adsp out of reset"
echo 1 > /sys/kernel/boot_adsp/boot

for _ in {1..200}; do
  [ "$(< "$state")" = "ONLINE" ] && break
  sleep 0.1
done
[ "$(< "$state")" = "ONLINE" ] || { echo "adsp failed to boot"; exit 1; }

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

# sound is ready, let clients in. opening a PCM before the ADSP is up floods the console with errors
find /dev/snd -maxdepth 1 -type c -exec chgrp audio {} + -exec chmod 660 {} +

# setup the amplifier registers
/usr/local/venv/bin/python /usr/comma/sound/amplifier.py
