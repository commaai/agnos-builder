#!/usr/bin/env python
import os
import signal
import time
import smbus2
import select
import datetime
import subprocess

ALERT_VOLTAGE_THRESHOLD_mV = 4000

POWER_ALERT_GPIO_PIN = 1264
INA231_BUS = 0
INA231_ADDRESS = 0x40
INA231_MASK_REG = 0x06
INA231_LIMIT_REG = 0x07
INA231_MASK_CONFIG = (1 << 12) # Bus undervoltage, not latching
INA231_BUS_VOLTAGE_LSB_mV = 1.25
VOLTAGE_FILE = "/sys/class/hwmon/hwmon1/in1_input"
PARAM_FILE = "/data/params/d/LastPowerDropDetected"
COMMA_CGROUP_PROCS = "/sys/fs/cgroup/comma/cgroup.procs"
COMMA_SV_CONTROL = "/run/runit/service/comma/supervise/control"

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

def read_current_mA():
  with open("/sys/class/hwmon/hwmon1/curr1_input", "r") as f:
    return int(f.read().strip())

def update_param(stage, v_initial, i_initial, v_final, i_final):
  try:
    os.umask(0)
    with open(os.open(PARAM_FILE, os.O_CREAT | os.O_WRONLY, 0o777), 'a') as f:
      f.write(f"{stage} {datetime.datetime.now()}, ({v_initial=} mV, {i_initial=} mA) -> ({v_final=} mV, {i_final=} mA)\n")
      f.flush()
      os.fdatasync(f.fileno())
      os.fsync(f.fileno())
  except Exception:
    print("Failed to update LastControlledShutdown param")

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
    return

  # Kill screen power immediately
  set_screen_power(False)

  update_param("SHUTDOWN", v_initial, i_initial, v_now, i_now)

  # Kill services that draw a lot of power
  # Offroad: ~150ms kill + ~10ms sync. Onroad: ~400ms kill + ~300ms sync (video encoders, dirty pages)
  printk("Killing services")
  # Tell runsv not to restart the service (write "d" to its control pipe)
  open(COMMA_SV_CONTROL, "wb", buffering=0).write(b"d")
  # SIGKILL all processes in the comma cgroup (comma/run puts all openpilot procs in this cgroup)
  [os.kill(int(p), signal.SIGKILL) for p in open(COMMA_CGROUP_PROCS).read().split() if p.strip()]
  # Tell panda SoC is off so it doesn't spin up the fan
  write_once("/sys/class/gpio/gpio49/direction", "out")
  write_once("/sys/class/gpio/gpio49/value", "0")
  # Wait for all processes to fully exit before syncing (kernel resource cleanup takes ~150-400ms)
  while open(COMMA_CGROUP_PROCS).read().strip():
    time.sleep(0.001)

  printk("All processes dead, syncing")
  os.sync()

  printk("Halt")
  subprocess.call(["/usr/sbin/halt", "-f"])

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
    except Exception:
      pass

