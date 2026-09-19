#!/bin/bash
for policy in /sys/devices/system/cpu/cpufreq/policy{0,4}; do
  [[ -e "$policy/scaling_max_freq" ]] && echo 1689600 > "$policy/scaling_max_freq"
done
