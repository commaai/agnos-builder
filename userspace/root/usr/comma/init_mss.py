#!/usr/bin/python3
import signal

# Keep the modem subsystem powered while this process holds the device open.
with open("/dev/subsys_modem", "rb"):
  signal.pause()
