#!/usr/bin/env -S uv run --script
# /// script
# dependencies = ["pyusb"]
# ///
import os
import subprocess
import sys
import time

import usb.core


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
  def __init__(self):
    self.aux_ports = [
      (self.hub_location(Pins.USB7002_VID, Pins.USB7002_PID), "1"),
      (self.hub_location(Pins.USB4002_VID, Pins.USB4002_PID), "1"),
    ]
    self.dev = None

  def hub_location(self, vid, pid):
    needle = f"[{vid:04x}:{pid:04x} "
    for line in subprocess.check_output(["uhubctl", "-S"], text=True).splitlines():
      if line.startswith("Current status for hub ") and needle in line:
        return line.split()[4]
    raise SystemExit(f"could not find hub {vid:04x}:{pid:04x}")

  def _dev(self):
    self.dev = self.dev or usb.core.find(idVendor=Pins.HFC_VID, idProduct=Pins.HFC_PID)
    return self.dev

  def reg(self, addr, value=None):
    dev = self._dev()
    if value is None:
      return int.from_bytes(bytes(dev.ctrl_transfer(0xC0, 0x04, addr & 0xFFFF, addr >> 16, 4)), "little")
    dev.ctrl_transfer(0x40, 0x03, addr & 0xFFFF, addr >> 16, value.to_bytes(4, "little"))

  def gpio(self, bit, on):
    if on:
      self.reg(Pins.PIO96_OEN, self.reg(Pins.PIO96_OEN) & ~bit)
    else:
      self.reg(Pins.PIO96_OUT, self.reg(Pins.PIO96_OUT) & ~bit)
      self.reg(Pins.PIO96_OEN, self.reg(Pins.PIO96_OEN) | bit)

  def aux(self, action):
    for hub, port in self.aux_ports:
      subprocess.run(["uhubctl", "-S", "-e", "-l", hub, "-p", port, "-a", action], check=True)

  def reboot(self):
    self.aux("off")
    self.gpio(Pins.VIN_EN, False)
    time.sleep(0.1)
    self.gpio(Pins.VIN_EN, True)
    time.sleep(0.1)
    self.aux("on")

  def reboot_qdl(self):
    self.aux("on")
    self.gpio(Pins.VIN_EN, False)
    time.sleep(0.1)
    self.gpio(Pins.VIN_EN, True)

  def serial(self):
    os.execvp("screen", ["screen", "/dev/serial/by-id/usb-Microchip_Tech_USB2_Controller_Hub-if01", "115200"])


if __name__ == "__main__":
  mdma = Mdma()
  cmd = sys.argv[1] if len(sys.argv) > 1 else ""
  if cmd == "reboot":
    mdma.reboot()
  elif cmd == "reboot-qdl":
    mdma.reboot_qdl()
  elif cmd == "serial":
    mdma.serial()
  else:
    raise SystemExit(f"usage: {sys.argv[0]} {{reboot|reboot-qdl|serial}}")
