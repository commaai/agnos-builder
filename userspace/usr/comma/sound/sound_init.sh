#!/bin/bash

/usr/comma/sound/adsp-start.sh

insmod /usr/comma/sound/snd-soc-wcd9xxx.ko
insmod /usr/comma/sound/snd-soc-sdm845.ko

echo "waiting for sound card to come online"
while [ ! -d /proc/asound/sdm845tavilsndc ] || [ "$(cat /proc/asound/card0/state 2> /dev/null)" != "ONLINE" ] ; do
  sleep 0.01
done
echo "sound card online"

/usr/comma/sound/tinymix set "SEC_MI2S_RX Audio Mixer MultiMedia1" 1
/usr/comma/sound/tinymix set "MultiMedia1 Mixer TERT_MI2S_TX" 1
/usr/comma/sound/tinymix set "TERT_MI2S_TX Channels" Two

# setup the amplifier registers
/usr/local/venv/bin/python /usr/comma/sound/amplifier.py
