#!/usr/bin/env -S uv run --script
# /// script
# dependencies = ["pyusb"]
# ///
from dataclasses import dataclass
import os
import subprocess
import sys
import time

import usb.core


@dataclass(frozen=True)
class Gpio:
  name: str
  gpio: int
  pf: str
  u4_pin: int

  @property
  def bit(self):
    return 1 << (self.gpio - 64)


class Pins:
  HFC_VID = 0x0424
  HFC_PID = 0x704C
  USB7002_VID = 0x0424
  USB7002_PID = 0x7002
  AUX_USB3_HUB = "8-1.2"
  AUX_USB2_HUB = "7-1.2"
  AUX_PORT = "1"
  PIO96_OEN = 0xBF800908
  PIO96_OUT = 0xBF800928

  VIN_EN = Gpio("VIN_EN", 92, "PF28", 77)
  WATCHDOG_DISABLE_N = Gpio("WATCHDOG_DISABLE_N", 93, "PF29", 74)
  MSM_SRST = Gpio("MSM_SRST", 94, "PF30", 2)
  ST_RST = Gpio("ST_RST", 95, "PF31", 3)

  MDMA_J2 = {
    1: "GND", 2: "USB_VBUS_MICI", 3: "VPH_PWR", 4: "UBX_RST_N",
    5: "UBX_JTAG_TCK", 6: "UBX_JTAG_TDI", 7: "UBX_JTAG_TDO",
    8: "UBX_JTAG_TMS", 9: "VREG_LVS1A_1P8", 10: "GND",
    11: "MSM_SRST_N", 12: "MSM_TRST_N", 13: "MSM_JTAG_TCK",
    14: "MSM_JTAG_TDI", 15: "MSM_JTAG_TDO", 16: "MSM_JTAG_TMS",
    17: "VREG_S4A_1P8", 18: "VBAT", 19: "GND", 20: "VIN_DEV",
    21: "GND", 22: "5V", 23: "5V", 24: "MSM_UART_RX",
    25: "MSM_UART_TX", 26: "WDOG_DISABLE", 27: "FORCE_USB_BOOT",
    28: "PANDA_1V8", 29: "STM_JTAG_TMS", 30: "STM_JTAG_TDO",
    31: "STM_JTAG_TDI", 32: "STM_JTAG_TCK", 33: "STM_TRST_N",
    34: "ST_RST_N", 35: "PANDA_1V8_EN", 36: "STM_USB_D_N",
    37: "STM_USB_D_P", 38: "STM_USB_3V3", 39: "GND", 40: "VIN_DEV",
  }

  U4 = {
    1: "RESET_N", 2: "MSM_SRST/PF30/GPIO94", 3: "ST_RST/PF31/GPIO95",
    4: "AUX_VBUS_DET/DP1_VBUS_MON", 5: "AUX_D_P", 6: "AUX_D_N",
    7: "AUX_TX1_P", 8: "AUX_TX1_N", 9: "VDD12", 10: "AUX_RX1_P",
    11: "AUX_RX1_N", 12: "AUX_CC1", 13: "AUX_CC2", 14: "STM_USB_D_P",
    15: "STM_USB_D_N", 16: "AUX_TX2_P", 17: "AUX_TX2_N",
    19: "AUX_RX2_P", 20: "AUX_RX2_N", 21: "CFG_STRAP1",
    22: "CFG_STRAP2", 23: "CFG_STRAP3", 24: "TESTEN", 26: "VDD33",
    27: "DP2_CC1", 28: "DP2_CC2", 29: "USB2DN_DP2", 30: "USB2DN_DM2",
    31: "USB3DN_TXDP2A", 32: "USB3DN_TXDM2A", 34: "USB3DN_RXDP2A",
    35: "USB3DN_RXDM2A", 36: "DP2_VBUS_MON", 37: "USB2DN_DP4",
    38: "USB2DN_DM4", 39: "USB3DN_TXDP2B", 40: "USB3DN_TXDM2B",
    42: "USB3DN_RXDP2B", 43: "USB3DN_RXDM2B", 45: "PF4",
    46: "AUX_VBUS_DRAIN/PF5", 47: "MSM_UART_TX/PF6",
    48: "MSM_UART_RX/PF7", 49: "DP1_VCONN1/PF8",
    50: "DP1_VCONN2/PF9", 51: "PF10", 52: "PF11", 54: "PF12",
    56: "PF13", 57: "PF14", 58: "PF15", 59: "STM_VBUS_EN/PF16",
    60: "AUX_VBUS_EN/PF17", 61: "PF18", 63: "TEST1",
    64: "TEST2", 65: "TEST3", 66: "PF19", 68: "PF21",
    69: "PF20/CFG_NON_REM", 70: "PF22/CFG_BC_EN", 71: "PF23",
    72: "PF24", 73: "PF25", 74: "WATCHDOG_DISABLE_N/PF29/GPIO93",
    75: "PF26", 76: "PF27", 77: "VIN_EN/PF28/GPIO92",
    80: "UFP_VBUS_DET/VBUS_MON_UP", 81: "UFP_USB_TX2_P",
    82: "UFP_USB_TX2_N", 84: "UFP_USB_RX2_P", 85: "UFP_USB_RX2_N",
    87: "UFP_CC1", 88: "UFP_CC2", 89: "UFP_USB_D_P",
    90: "UFP_USB_D_N", 91: "UFP_USB_TX1_P", 92: "UFP_USB_TX1_N",
    94: "UFP_USB_RX1_P", 95: "UFP_USB_RX1_N", 96: "ATEST",
    97: "XTAL_OUT", 98: "XTAL_IN", 100: "RBIAS",
  }


class Mdma:
  def __init__(self):
    self.aux_ports = [
      (os.getenv("MDMA_USB3_HUB_LOCATION", Pins.AUX_USB3_HUB), os.getenv("MDMA_USB3_PORT", Pins.AUX_PORT)),
      (os.getenv("MDMA_USB2_HUB_LOCATION", Pins.AUX_USB2_HUB), os.getenv("MDMA_USB2_PORT", Pins.AUX_PORT)),
    ]
    self.dev = None

  def _dev(self):
    self.dev = self.dev or usb.core.find(idVendor=Pins.HFC_VID, idProduct=Pins.HFC_PID)
    return self.dev

  def reg(self, addr, value=None):
    dev = self._dev()
    if value is None:
      return int.from_bytes(bytes(dev.ctrl_transfer(0xC0, 0x04, addr & 0xFFFF, addr >> 16, 4)), "little")
    dev.ctrl_transfer(0x40, 0x03, addr & 0xFFFF, addr >> 16, value.to_bytes(4, "little"))

  def gpio(self, pin, on):
    if on:
      self.reg(Pins.PIO96_OEN, self.reg(Pins.PIO96_OEN) & ~pin.bit)
    else:
      self.reg(Pins.PIO96_OUT, self.reg(Pins.PIO96_OUT) & ~pin.bit)
      self.reg(Pins.PIO96_OEN, self.reg(Pins.PIO96_OEN) | pin.bit)

  def aux(self, action):
    for hub, port in self.aux_ports:
      subprocess.run(["uhubctl", "-S", "-e", "-l", hub, "-p", port, "-a", action], check=True)

  def reboot(self):
    self.aux("off"); time.sleep(1)
    self.gpio(Pins.VIN_EN, False); time.sleep(5)
    self.gpio(Pins.VIN_EN, True); time.sleep(float(os.getenv("MDMA_BOOT_DELAY", "20")))
    self.aux("on")

  def reboot_qdl(self):
    self.aux("on")
    self.gpio(Pins.VIN_EN, False); time.sleep(5)
    self.gpio(Pins.VIN_EN, True); time.sleep(float(os.getenv("MDMA_QDL_DELAY", "3")))


mdma = Mdma()
cmd = sys.argv[1] if len(sys.argv) > 1 else ""
if cmd == "reboot":
  mdma.reboot()
elif cmd == "reboot-qdl":
  mdma.reboot_qdl()
else:
  raise SystemExit(f"usage: {sys.argv[0]} {{reboot|reboot-qdl}}")
