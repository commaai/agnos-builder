#!/bin/sh
# uevent-helper.service points the kernel at this, it runs for every uevent so keep it cheap
# new USB devices are root only, this lets the comma user open them
[ "$ACTION" = add ] && [ "$DEVTYPE" = usb_device ] || exit 0
chmod 664 "/dev/$DEVNAME"
