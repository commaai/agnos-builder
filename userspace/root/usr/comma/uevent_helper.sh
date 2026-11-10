#!/bin/sh
# uevent-helper.service points the kernel at this, it runs for every uevent so keep it cheap.

setup_device() {
  # The node can disappear again before its add event is handled.
  [ -e "/dev/$3" ] || return 0
  case "$1" in
    input)
      case "$3" in
        input/*)
          chgrp input "/dev/$3"
          chmod 666 "/dev/$3"
          case "$2:$3" in
            /devices/platform/soc/894000.i2c/*:input/event*)
              mkdir -p /dev/input/by-path
              ln -sfn "../${3#input/}" /dev/input/by-path/platform-894000.i2c-event
              ;;
          esac
          ;;
      esac
      ;;
    video4linux|media)
      chgrp video "/dev/$3"
      chmod 660 "/dev/$3"
      case "$2" in
        /devices/platform/soc/soc:qcom,cam-req-mgr/video4linux/video*)
          alias=platform-soc:qcom_cam-req-mgr-video-index0 ;;
        /devices/platform/cam_sync/video4linux/video*)
          alias=platform-cam_sync-video-index0 ;;
        /devices/platform/soc/aa00000.qcom,vidc/video4linux/video*)
          [ "$(cat "/sys$2/index")" = 1 ] || return 0
          alias=platform-aa00000.qcom_vidc-video-index1 ;;
        *) return 0 ;;
      esac
      mkdir -p /dev/v4l/by-path
      ln -sfn "../../$3" "/dev/v4l/by-path/$alias"
      ;;
    usb)
      [ "$DEVTYPE" = usb_device ] && chmod 664 "/dev/$3"
      ;;
    tty)
      # Modem ports can return without modem.py starting over.
      case "$3" in
        ttyUSB*)
          chgrp dialout "/dev/$3"
          chmod 660 "/dev/$3"
          ;;
      esac
      ;;
  esac
}

if [ "$1" = --reconcile ]; then
  # Install the helper before this sweep so additions on either side are covered.
  for subsystem in input video4linux media; do
    for entry in /sys/class/"$subsystem"/*; do
      [ -f "$entry/uevent" ] || continue
      devname=$(sed -n 's/^DEVNAME=//p' "$entry/uevent")
      [ -n "$devname" ] || continue
      path=$(readlink -f "$entry")
      setup_device "$subsystem" "${path#/sys}" "$devname"
    done
  done
  for node in /dev/bus/usb/*/*; do
    [ ! -e "$node" ] || chmod 664 "$node"
  done
  exit 0
fi

[ "$ACTION" = add ] || exit 0
case "$SUBSYSTEM" in
  gpio)
    d=/sys$DEVPATH
    chgrp -f gpio "$d" "$d/active_low" "$d/direction" "$d/edge" "$d/value"
    chmod -f 770 "$d" "$d/active_low" "$d/direction" "$d/edge" "$d/value"
    ;;
  *)
    [ -n "$DEVNAME" ] && setup_device "$SUBSYSTEM" "$DEVPATH" "$DEVNAME"
    ;;
esac
