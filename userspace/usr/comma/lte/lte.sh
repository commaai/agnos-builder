#!/bin/bash

function gpio {
  echo "out" > /sys/class/gpio/gpio$1/direction
  echo $2 > /sys/class/gpio/gpio$1/value
}

HUB_RST_N=30
LTE_RST_N=50
LTE_BOOT=52
LTE_PWRKEY=116

function is_modem_up {
  if lsusb -d "0x05c6:" >/dev/null 2>&1 || lsusb -d "0x2c7c:" >/dev/null 2>&1; then
    return 0
  else
    return 1
  fi
}

function reset {
  echo " Resetting..."
  gpio $LTE_RST_N 1
  sleep 1
  gpio $LTE_RST_N 0
}

function power_button {
  echo " Pulsing power button..."
  gpio $LTE_PWRKEY 1
  sleep 1
  gpio $LTE_PWRKEY 0
}

function is_online {
  echo " Waiting until the modem comes online..."

  for i in {0..30}; do
    if is_modem_up; then
      echo "  Modem is online!"
      return 0
    fi

    echo "  Waiting..."
    sleep 1
  done

  return 1
}

function is_offline {
  echo " Waiting until the modem goes offline..."

  for i in {0..30}; do
    if ! is_modem_up; then
      echo "  Modem is offline!"
      return 0
    fi

    echo "  Waiting..."
    sleep 1
  done

  return 1
}

# Boot into the regular mode
gpio $LTE_BOOT 0

case "$1" in
  start)
    echo "Starting LTE..."

    reset
    power_button
    until is_online; do
      reset
      power_button
    done

    ;;
  stop)
    echo "Stopping LTE..."

    if is_online; then
      power_button
    fi

    ;;
  stop_blocking)
    echo "Stopping LTE..."

    if is_online; then
      power_button
    fi

    until is_offline; do
      power_button
    done

    ;;
  *)
    echo "Specify either start or stop as first argument!"
    exit 1
    ;;
esac
