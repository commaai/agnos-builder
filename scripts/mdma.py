#!/usr/bin/env -S uv run --script
# /// script
# dependencies = ["pyusb"]
# ///
import argparse
import errno
import fcntl
import os
import re
import select
import sys
import termios
import time

import usb.core

SERIAL_DEV = "/dev/serial/by-id/usb-Microchip_Tech_USB2_Controller_Hub-if01"
PROMPT_RE = re.compile(rb"(?:login:|[#\$])$")
USB_RT_PORT = 0x23
USB_REQ_CLEAR_FEATURE = 1
USB_REQ_SET_FEATURE = 3
USB_PORT_POWER = 8


class Pins:
  HFC_VID = 0x0424
  HFC_PID = 0x704C
  USB7002_VID = 0x0424
  USB7002_PID = 0x7002
  USB4002_VID = 0x0424
  USB4002_PID = 0x4002
  PIO96_OEN = 0xBF800908
  PIO96_OUT = 0xBF800928
  VIN_EN = 1 << (92 - 64)


class Mdma:
  """
    MDMA: the mici debug and monitoring adapter

    an MDMA is your best friend for low level mici (aka comma four) development.
    - power the SOC on and off
    - force the SOC into QDL mode for un-brickability
    - read and write to the SOC's UART
    - and more!
  """

  def hub(self, vid, pid):
    hub = usb.core.find(idVendor=vid, idProduct=pid)
    if hub is None:
      raise SystemExit(f"could not find hub {vid:04x}:{pid:04x}")
    return hub

  def available(self):
    return os.path.exists(SERIAL_DEV)

  def reg(self, addr, value=None, size=4):
    dev = usb.core.find(idVendor=Pins.HFC_VID, idProduct=Pins.HFC_PID)
    if value is None:
      return int.from_bytes(bytes(dev.ctrl_transfer(0xC0, 0x04, addr & 0xFFFF, addr >> 16, size)), "little")
    dev.ctrl_transfer(0x40, 0x03, addr & 0xFFFF, addr >> 16, value.to_bytes(size, "little"))

  def gpio(self, bit, on):
    if on:
      self.reg(Pins.PIO96_OEN, self.reg(Pins.PIO96_OEN) & ~bit)
    else:
      self.reg(Pins.PIO96_OUT, self.reg(Pins.PIO96_OUT) & ~bit)
      self.reg(Pins.PIO96_OEN, self.reg(Pins.PIO96_OEN) | bit)

  def aux(self, action):
    request = USB_REQ_SET_FEATURE if action == "on" else USB_REQ_CLEAR_FEATURE
    for vid, pid in [(Pins.USB7002_VID, Pins.USB7002_PID),  (Pins.USB4002_VID, Pins.USB4002_PID)]:
      try:
        self.hub(vid, pid).ctrl_transfer(USB_RT_PORT, request, USB_PORT_POWER, 1, None, timeout=1000)
      except usb.core.USBError: # try one more time
        self.hub(vid, pid).ctrl_transfer(USB_RT_PORT, request, USB_PORT_POWER, 1, None, timeout=1000)

  def power_off(self):
    self.aux("off")
    self.gpio(Pins.VIN_EN, False)

  def reboot(self, qdl):
    self.aux("off")
    self.gpio(Pins.VIN_EN, False)
    time.sleep(0.1)
    if qdl:
      # on comma 3X and comma four, aux powering
      # up first forces QDL mode on boot
      self.aux("on")
    else:
      self.gpio(Pins.VIN_EN, True)
    boot_time = time.monotonic()
    time.sleep(0.1)
    self.gpio(Pins.VIN_EN, True)
    self.aux("on")

    # give time to enumerate
    if qdl:
      time.sleep(1)

    return boot_time

  def serial(self):
    os.execvp("screen", ["screen", SERIAL_DEV, "115200"])

  def profile_boot(self):
    # device off for clean serial
    self.power_off()

    # open the serial device
    try:
      fd = os.open(SERIAL_DEV, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    except OSError as e:
      if e.errno == errno.EBUSY:
        raise SystemExit(f"{SERIAL_DEV} is busy; close the serial console first")
      raise

    attrs = termios.tcgetattr(fd)
    attrs[0] = 0
    attrs[1] = 0
    attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    attrs[3] = 0
    attrs[4] = termios.B115200
    attrs[5] = termios.B115200
    attrs[6][termios.VMIN] = 0
    attrs[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, attrs)
    fcntl.fcntl(fd, fcntl.F_SETFL, fcntl.fcntl(fd, fcntl.F_GETFL) & ~os.O_NONBLOCK)
    termios.tcflush(fd, termios.TCIFLUSH)
    while (data := os.read(fd, 4096)):
      time.sleep(0.1)

    # boot!
    start = self.reboot(qdl=False)

    # show serial console with timestamps until boot is done
    pending = b""
    while True:
      if not select.select([fd], [], [], 0.25)[0]:
        continue

      data = os.read(fd, 4096)
      if not data:
        continue
      pending += data.replace(b"\r\n", b"\n")
      while b"\n" in pending:
        line, pending = pending.split(b"\n", 1)
        line = line.rstrip()
        print(f"[{time.monotonic() - start:8.3f}] {line.decode(errors='replace')}", flush=True)
        if PROMPT_RE.search(line):
          return
      if PROMPT_RE.search(pending.strip()):
        print(f"[{time.monotonic() - start:8.3f}] {pending.strip().decode(errors='replace')}", flush=True)
        return


if __name__ == "__main__":
  cmds = {
    "reboot":       (lambda: Mdma().reboot(qdl=False), "reboot comma four into normal boot"),
    "reboot-qdl":   (lambda: Mdma().reboot(qdl=True), "reboot comma four into QDL mode for flashing"),
    "serial":       (lambda: Mdma().serial(), "open the MSM UART console with screen"),
    "profile-boot": (lambda: Mdma().profile_boot(), "reboot comma four and profile boot time"),
  }

  parser = argparse.ArgumentParser()
  parser.add_argument("--missing-ok", action="store_true", help="continue successfully when no MDMA is connected")
  subparsers = parser.add_subparsers(dest="command", required=True)
  for cmd, (_, hlp) in cmds.items():
    subparsers.add_parser(cmd, help=hlp)
  if len(sys.argv) == 1:
    parser.print_help()
    raise SystemExit(0)
  args = parser.parse_args()

  if not Mdma().available():
    print("MDMA not found.")
    raise SystemExit(0 if args.missing_ok else 1)

  cmds[args.command][0]()
