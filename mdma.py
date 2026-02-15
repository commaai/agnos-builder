#!/usr/bin/env python3
"""
mdma_desk control library

FT230X CBUS GPIO mapping:
  CBUS0: AUX USB passthrough enable   (HIGH = passthrough on)
  CBUS1: Device power VIN enable       (HIGH = power on)
  CBUS2: Watchdog enable               (HIGH = WDOG_DISABLE pulled low, watchdog active)
  CBUS3: STM VBUS disable              (HIGH = STM_VBUS_EN pulled low, STM USB off)

Default state (all CBUS low):
  AUX USB off, device power off, watchdog disabled, STM VBUS on

Prerequisites:
  pip install pyftdi
  FT230X EEPROM: CBUS0-3 must be configured as GPIO (I/O mode)
  Linux: unload ftdi_sio kernel module or add udev rule for pyftdi access

AUX USB note:
  The USB-C passthrough (J1<->J4) only works in one cable orientation.
  If the device doesn't enumerate after enabling aux_usb, flip the cable.
"""

import subprocess
import sys
import time
import threading
from pyftdi.ftdi import Ftdi


# Qualcomm USB identifiers
QDL_VID_PID = '05c6:9008'


class MdmaDesk:
  CBUS_AUX_EN = 1 << 0        # CBUS0 - AUX USB passthrough
  CBUS_VIN_EN = 1 << 1        # CBUS1 - device power
  CBUS_WDOG_EN = 1 << 2       # CBUS2 - watchdog enable (inverted by Q4)
  CBUS_STM_VBUS_DIS = 1 << 3  # CBUS3 - STM VBUS disable (inverted by Q4)

  def __init__(self, url='ftdi://ftdi:ft-x/1', baudrate=115200):
    self._ftdi = Ftdi()
    self._ftdi.open_from_url(url)
    self._ftdi.set_baudrate(baudrate)
    self._ftdi.set_line_property(8, 1, 'N')
    self._ftdi.set_flowctrl('')
    self._cbus = 0x00
    self._ftdi.set_cbus_direction(0x0F, 0x0F)  # all 4 CBUS as outputs
    self._ftdi.set_cbus_gpio(self._cbus)

  def _set_cbus(self, mask, on):
    if on:
      self._cbus |= mask
    else:
      self._cbus &= ~mask
    self._ftdi.set_cbus_gpio(self._cbus)

  # -- power & control --

  def power(self, on=True):
    """Enable/disable device power (VIN from external supply)."""
    self._set_cbus(self.CBUS_VIN_EN, on)

  def aux_usb(self, on=True):
    """Enable/disable AUX USB passthrough (J1 host <-> J4 device).
    Only works in one USB-C cable orientation - flip cable if no enumeration."""
    self._set_cbus(self.CBUS_AUX_EN, on)

  def watchdog(self, on=True):
    """Enable/disable the device watchdog.
    Default HW state is disabled (WDOG_DISABLE pulled high by R26)."""
    self._set_cbus(self.CBUS_WDOG_EN, on)

  def stm_vbus(self, on=True):
    """Enable/disable STM32 USB VBUS.
    Default HW state is enabled (STM_VBUS_EN pulled high by R5)."""
    self._set_cbus(self.CBUS_STM_VBUS_DIS, not on)

  # -- serial I/O --

  @property
  def baudrate(self):
    return self._ftdi.baudrate

  @baudrate.setter
  def baudrate(self, rate):
    self._ftdi.set_baudrate(rate)

  def read(self, size=1024):
    """Read up to size bytes from MSM UART."""
    return self._ftdi.read_data(size)

  def write(self, data):
    """Write to MSM UART. Accepts str or bytes."""
    if isinstance(data, str):
      data = data.encode()
    return self._ftdi.write_data(data)

  def drain(self):
    """Discard any pending serial data."""
    while self.read(4096):
      pass

  def read_until(self, pattern, timeout=30, stream=True):
    """Read serial data until pattern is found.
    Returns all accumulated bytes. Raises TimeoutError on timeout.
    stream=True prints data to stdout in real-time."""
    if isinstance(pattern, str):
      pattern = pattern.encode()
    buf = b''
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
      d = self.read(4096)
      if d:
        buf += d
        if stream:
          sys.stdout.buffer.write(d)
          sys.stdout.buffer.flush()
        if pattern in buf:
          return buf
      else:
        time.sleep(0.01)
    raise TimeoutError(f'{pattern!r} not found in {timeout}s')

  # -- higher-level helpers --

  def reboot(self):
    """Power cycle the device."""
    self.power(False)
    time.sleep(0.5)
    self.power(True)

  def shell(self, cmd, timeout=10):
    """Send a shell command over UART and return its output.
    Requires a root shell on the serial console."""
    self.drain()
    marker = f'MDMA{int(time.monotonic() * 1e9)}'
    self.write(f"{cmd}; echo {marker}\n")
    out = self.read_until(marker.encode(), timeout=timeout, stream=False)
    text = out.decode(errors='replace')
    # strip marker and everything after it
    idx = text.rfind(marker)
    if idx >= 0:
      text = text[:idx]
    # skip the echoed command (first line)
    nl = text.find('\n')
    if nl >= 0:
      text = text[nl + 1:]
    return text.strip()

  def enter_qdl(self, timeout=60):
    """Put device into QDL mode for flashing via EDL.
    Sends 'reboot edl' over UART, enables AUX USB, waits for QDL device.
    Flip the AUX USB-C cable if device doesn't enumerate."""
    self.aux_usb(True)
    self.drain()
    self.write('\nreboot edl\n')
    self.wait_for_qdl(timeout)

  def wait_for_qdl(self, timeout=60):
    """Wait for QDL USB device (05c6:9008) to appear on the host."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
      if self._usb_present(QDL_VID_PID):
        return
      time.sleep(0.5)
    raise TimeoutError(
      f'QDL device ({QDL_VID_PID}) not found in {timeout}s - '
      f'try flipping the AUX USB-C cable'
    )

  @staticmethod
  def _usb_present(vid_pid):
    """Check if a USB device with given VID:PID is present."""
    return subprocess.run(
      ['lsusb', '-d', vid_pid],
      capture_output=True,
    ).returncode == 0

  # -- lifecycle --

  def close(self):
    """Reset all CBUS to low and close."""
    try:
      self._cbus = 0x00
      self._ftdi.set_cbus_gpio(self._cbus)
    except Exception:
      pass
    self._ftdi.close()

  def __enter__(self):
    return self

  def __exit__(self, *args):
    self.close()

  def __repr__(self):
    state = []
    if self._cbus & self.CBUS_VIN_EN:
      state.append('power=on')
    else:
      state.append('power=off')
    if self._cbus & self.CBUS_AUX_EN:
      state.append('aux_usb=on')
    if self._cbus & self.CBUS_WDOG_EN:
      state.append('watchdog=on')
    if self._cbus & self.CBUS_STM_VBUS_DIS:
      state.append('stm_vbus=off')
    return f'MdmaDesk({", ".join(state)})'


if __name__ == '__main__':
  print('mdma_desk serial monitor (Ctrl+C to exit)')

  with MdmaDesk() as m:
    m.power(True)
    print(f'power on - {m}')

    def _reader():
      while True:
        d = m.read(4096)
        if d:
          sys.stdout.buffer.write(d)
          sys.stdout.buffer.flush()
        else:
          time.sleep(0.01)

    t = threading.Thread(target=_reader, daemon=True)
    t.start()

    try:
      while True:
        line = sys.stdin.readline()
        if not line:
          break
        m.write(line)
    except KeyboardInterrupt:
      pass

    m.power(False)
    print('\npower off, closing')
