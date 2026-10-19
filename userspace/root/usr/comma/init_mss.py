#!/usr/bin/python3
import signal

# The on-chip Wi-Fi firmware runs in the SDM845 modem subsystem.
# Opening this device boots it and holds a reference; the kernel shuts it
# down when the last reference is released. Keep it open for this service's
# lifetime so Wi-Fi stays available.
# https://github.com/commaai/agnos-kernel-sdm845/blob/8b0e4d289b246a5cc1b0484b25a3f9f8d4772544/drivers/soc/qcom/subsystem_restart.c#L1215-L1251
with open("/dev/subsys_modem", "rb"):
  signal.pause()
