#!/bin/sh
# uevent-helper.service points the kernel at this, it runs for every uevent so keep it cheap
# new nodes are root only, this gives comma the ones that can come back after boot
[ "$ACTION" = add ] || exit 0
case "$SUBSYSTEM" in
  usb)
    [ "$DEVTYPE" = usb_device ] && chmod 664 "/dev/$DEVNAME"
    ;;
  input)
    case "$DEVNAME" in
      input/event*|input/mouse*)
        chgrp input "/dev/$DEVNAME"
        chmod 666 "/dev/$DEVNAME"
        ;;
    esac
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
  video4linux|media)
    chgrp video "/dev/$DEVNAME"
    chmod 660 "/dev/$DEVNAME"
    ;;
  block)
    chgrp disk "/dev/$DEVNAME"
    chmod 660 "/dev/$DEVNAME"
    ;;
  gpio)
    d=/sys$DEVPATH
    chgrp -f gpio "$d" "$d/active_low" "$d/direction" "$d/edge" "$d/value"
    chmod -f 770 "$d" "$d/active_low" "$d/direction" "$d/edge" "$d/value"
    ;;
esac
