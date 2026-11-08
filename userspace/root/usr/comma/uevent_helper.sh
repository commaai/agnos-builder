#!/bin/sh
# uevent-helper.service points the kernel at this, it runs for every uevent so keep it cheap
# new nodes are root only. boot.sh sets up the rest once, these are the ones that can come and go after it:
# USB and input devices, the modem's ports when it resets, and GPIOs exported later
[ "$ACTION" = add ] || exit 0
case "$SUBSYSTEM" in
  input)
    case "$DEVNAME" in
      input/*)
        chgrp input "/dev/$DEVNAME"
        chmod 666 "/dev/$DEVNAME"
        ;;
    esac
    ;;
  usb)
    [ "$DEVTYPE" = usb_device ] && chmod 664 "/dev/$DEVNAME"
    ;;
  tty)
    # the modem's ports come back when it resets, modem.py only fixes them up when it starts over
    case "$DEVNAME" in
      ttyUSB*)
        chgrp dialout "/dev/$DEVNAME"
        chmod 660 "/dev/$DEVNAME"
        ;;
    esac
    ;;
  gpio)
    d=/sys$DEVPATH
    chgrp -f gpio "$d" "$d/active_low" "$d/direction" "$d/edge" "$d/value"
    chmod -f 770 "$d" "$d/active_low" "$d/direction" "$d/edge" "$d/value"
    ;;
esac
