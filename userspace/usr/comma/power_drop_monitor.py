#!/usr/bin/env python

import os
import sys
import time
import smbus2
import select
import datetime

ALERT_VOLTAGE_THRESHOLD_mV = 4000

POWER_ALERT_GPIO_PIN = 1264
INA231_BUS = 0
INA231_ADDRESS = 0x40
INA231_MASK_REG = 0x06
INA231_LIMIT_REG = 0x07
INA231_MASK_CONFIG = (1 << 12) # Bus undervoltage, not latching
INA231_BUS_VOLTAGE_LSB_mV = 1.25
VOLTAGE_FILE = f"/sys/class/hwmon/hwmon1/in1_input"

alert_pin_base = f"/sys/class/gpio/gpio{POWER_ALERT_GPIO_PIN}/"

def set_screen_power(on):
  with open("/sys/class/backlight/panel0-backlight/bl_power", "w") as f:
    f.write("0\n" if on else "4\n")

def get_screen_power():
  with open("/sys/class/backlight/panel0-backlight/bl_power", "r") as f:
    return f.read(1) == "0"

def swap_word_bytes(val):
  return ((val & 0xFF) << 8) | ((val & 0xFF00) >> 8)

def write_once(path, value):
  with open(path, 'w') as f:
    f.write(value)

def init_alert_pin():
  write_once(os.path.join(alert_pin_base, 'direction'), 'in')
  write_once(os.path.join(alert_pin_base, 'edge'), 'falling')

def init_voltage_alert():
  with smbus2.SMBus(INA231_BUS) as bus:
    bus.write_word_data(INA231_ADDRESS, INA231_MASK_REG, swap_word_bytes(INA231_MASK_CONFIG), force=True)
    bus.write_word_data(INA231_ADDRESS, INA231_LIMIT_REG, swap_word_bytes(int(ALERT_VOLTAGE_THRESHOLD_mV / INA231_BUS_VOLTAGE_LSB_mV)), force=True)

def read_voltage_mV():
  with open(VOLTAGE_FILE, "r") as f:
    return int(f.read().strip())

def perform_controlled_shutdown():
  print("Power alert received! Syncing. If voltage still low after 100ms, shutting down...")
  prev_screen_power = get_screen_power()
  set_screen_power(False)

  # Wait 100ms before checking voltage level
  t = time.monotonic()
  while time.monotonic() - t < 0.1:
    time.sleep(0.01)

  if read_voltage_mV() > ALERT_VOLTAGE_THRESHOLD_mV:
    print("Voltage restored. Not shutting down!")
    set_screen_power(prev_screen_power)
    return

  try:
    with open("/data/params/d/LastControlledShutdown", "w") as f:
      f.write(str(datetime.datetime.now()))
  except Exception:
    print("Failed to update LastControlledShutdown param")

  # Send a signal to loggerd that it's time to clean up
  os.system("pkill -SIGPWR loggerd")
  os.system("pkill -9 _ui")
  os.system("pkill -9 modeld")
  os.system("pkill -9 camerad")

  # Wait for loggerd to exit
  while os.system("pgrep loggerd") == 0:
    time.sleep(0.01)

  os.sync()
  os.system("halt -f")

if __name__ == '__main__':
  init_alert_pin()
  init_voltage_alert()

  # Setup interrupt
  f = open(os.path.join(alert_pin_base, 'value'), 'r')
  po = select.poll()
  po.register(f, select.POLLPRI)

  # Interrupt loop
  f.read()
  while True:
    try:
      events = po.poll(60000)
      if events:
        f.seek(0)
        state_last = f.read().strip()
        if int(state_last) == 0:
          perform_controlled_shutdown()
    except:
      pass

