#!/bin/bash

# Mainline assigns GPIO bases dynamically; downstream TLMM starts at zero.
TLMM_BASE=$(cat /sys/bus/platform/devices/3400000.pinctrl/gpio/*/base 2>/dev/null | head -1)
TLMM_BASE=${TLMM_BASE:-0}

gpio_number() {
  echo $((TLMM_BASE + $1))
}

gpio() {
  local pin=$(gpio_number "$1")
  echo out > /sys/class/gpio/gpio$pin/direction
  echo "$2" > /sys/class/gpio/gpio$pin/value
}
