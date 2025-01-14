#!/usr/bin/env python3
import fcntl

KDSETMODE = 0x4B3A
KD_TEXT = 0x00
 
if __name__ == "__main__":
  with open("/dev/tty1", "w") as fd:
    try:
      fcntl.ioctl(fd, KDSETMODE, KD_TEXT)
    except OSError as e:
      print(f"Error setting tty1 in text mode: {e}")
