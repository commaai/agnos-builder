#!/usr/bin/env python3
import os
import glob
import time
import datetime
import subprocess

import gpiod

ALERT_VOLTAGE_THRESHOLD_mV = 4000

# The INA231 ALERT output, PM8998 GPIO5 on tizi, named in the board DT
ALERT_GPIO_LINE = "POWER_ALERT"
PARAM_FILE = "/data/params/d/LastPowerDropDetected"

def find_backlight():
  backlights = glob.glob("/sys/class/backlight/*")
  if not backlights:
    raise RuntimeError("no backlight device")
  return backlights[0]

def find_ina231():
  for p in glob.glob("/sys/class/hwmon/hwmon*/name"):
    with open(p) as f:
      if f.read().strip() == "ina231":
        return os.path.dirname(p)
  raise RuntimeError("no ina231 hwmon device")

def set_screen_power(on):
  with open(f"{backlight}/bl_power", "w") as f:
    f.write("0\n" if on else "4\n")

def get_screen_power():
  with open(f"{backlight}/bl_power", "r") as f:
    return f.read(1) == "0"

def read_hwmon(attr):
  with open(f"{ina231}/{attr}", "r") as f:
    return int(f.read().strip())

def read_voltage_mV():
  return read_hwmon("in1_input")

def read_current_mA():
  return read_hwmon("curr1_input")

def request_alert_line():
  line = gpiod.find_line(ALERT_GPIO_LINE)
  if line is None:
    raise RuntimeError(f"no GPIO line {ALERT_GPIO_LINE}")
  line.request(consumer="power_drop_monitor", type=gpiod.LINE_REQ_EV_FALLING_EDGE, flags=gpiod.LINE_REQ_FLAG_BIAS_PULL_UP)
  return line

def init_voltage_alert():
  # the ina2xx driver programs the bus undervoltage alert, latched until
  # in1_lcrit_alarm is read
  with open(f"{ina231}/in1_lcrit", "w") as f:
    f.write(f"{ALERT_VOLTAGE_THRESHOLD_mV}\n")
  read_hwmon("in1_lcrit_alarm")

def update_param(stage, v_initial, i_initial, v_final, i_final):
  try:
    os.umask(0)
    with open(os.open(PARAM_FILE, os.O_CREAT | os.O_WRONLY, 0o777), 'a') as f:
      f.write(f"{stage} {datetime.datetime.now()}, ({v_initial=} mV, {i_initial=} mA) -> ({v_final=} mV, {i_final=} mA)\n")
      f.flush()
      os.fdatasync(f.fileno())
      os.fsync(f.fileno())
  except Exception as e:
    print(f"Failed to update {PARAM_FILE}: {e}")

def printk(msg):
  with open('/dev/kmsg', 'w') as kmsg:
    kmsg.write(f"<3>[power drop monitor] {msg}\n")
  print(msg)

def perform_controlled_shutdown():
  printk("Power alert received!")

  prev_screen_power = get_screen_power()
  set_screen_power(False)

  v_initial = read_voltage_mV()
  i_initial = read_current_mA()
  update_param("PREP", v_initial, i_initial, None, None)

  # Wait 100ms before checking voltage level again
  t = time.monotonic()
  while time.monotonic() - t < 0.1:
    time.sleep(0.01)

  v_now = read_voltage_mV()
  i_now = read_current_mA()
  if v_now > ALERT_VOLTAGE_THRESHOLD_mV:
    printk("Voltage restored. Not shutting down!")
    update_param("ABORT", v_initial, i_initial, v_now, i_now)
    set_screen_power(prev_screen_power)
    read_hwmon("in1_lcrit_alarm")
    return

  update_param("SHUTDOWN", v_initial, i_initial, v_now, i_now)

  set_screen_power(False)

  printk("Halt")
  subprocess.call(["/usr/sbin/halt", "-f"])

if __name__ == '__main__':
  # Any error, including a device that hasn't probed yet (ina2xx is a
  # module), exits; systemd restarts the service, which also re-arms the
  # latched alert.
  backlight = find_backlight()
  ina231 = find_ina231()
  line = request_alert_line()
  init_voltage_alert()

  while True:
    if line.event_wait(sec=60):
      line.event_read()
      perform_controlled_shutdown()
