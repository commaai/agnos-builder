#!/bin/bash

# don't restart whole SoC on subsystem crash
for i in {0..7}; do
  echo "related" > /sys/bus/msm_subsys/devices/subsys${i}/restart_level
done
