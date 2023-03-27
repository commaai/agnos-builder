#!/bin/bash

/usr/comma/sound/adsp-start.sh

insmod /usr/comma/sound/snd-soc-wcd9xxx.ko
insmod /usr/comma/sound/snd-soc-sdm845.ko

/usr/comma/sound/tinymix set "SEC_MI2S_RX Audio Mixer MultiMedia1" 1
/usr/comma/sound/tinymix set "MultiMedia1 Mixer TERT_MI2S_TX" 1

# setup the amplifier registers
/usr/local/pyenv/shims/python /usr/comma/sound/amplifier.py
