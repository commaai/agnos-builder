#!/usr/local/pyenv/shims/python3
import sys

import usb1

REQUEST_OUT = usb1.ENDPOINT_OUT | usb1.TYPE_VENDOR | usb1.RECIPIENT_DEVICE

USB_POWER_MODE = 0xe6
USB_POWER_CLIENT = 1

if __name__ == "__main__":
  if len(sys.argv) > 1 and sys.argv[1] in ['halt', 'poweroff']:
    ctx = usb1.USBContext()
    dev = ctx.openByVendorIDAndProductID(0xbbaa, 0xddcc)

    if dev is not None:
      dev.controlWrite(REQUEST_OUT, USB_POWER_MODE, USB_POWER_CLIENT, 0, b'')
      print("Disabled bootkick")
    else:
      print("No panda found")
  else:
    print("Please specify shutdown reason")
