#!/bin/bash
# each init starts immediately in the background and waits for whatever it needs itself

# don't restart whole SoC on subsystem crash. this has to happen before anything below boots
for i in {0..7}; do
  echo "related" > /sys/bus/msm_subsys/devices/subsys${i}/restart_level
done

# the video core boots on first open, openpilot's booted check waits for it
timeout 10 bash -c ": < /dev/video33" &
