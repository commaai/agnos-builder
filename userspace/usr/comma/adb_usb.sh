#!/bin/sh
#
# Copyright (c) 2012-2015, 2018, The Linux Foundation. All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#     * Redistributions of source code must retain the above copyright
#       notice, this list of conditions and the following disclaimer.
#     * Redistributions in binary form must reproduce the above copyright
#       notice, this list of conditions and the following disclaimer in the
#       documentation and/or other materials provided with the distribution.
#     * Neither the name of The Linux Foundation nor the names of its
#       contributors may be used to endorse or promote products derived from
#       this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES,
# INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NON-INFRINGEMENT ARE DISCLAIMED.  IN NO
# EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
# INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
# (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
# LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
# ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
# SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

case "$1" in
  start)
    # Mount configfs and create ADB function
    mount -t configfs none /sys/kernel/config
    if [ -d /sys/kernel/config/usb_gadget ]; then
      cd /sys/kernel/config/usb_gadget
      mkdir g1
      cd g1
      mkdir strings/0x409
      mkdir configs/c.1
      mkdir configs/c.1/strings/0x409
      mkdir functions/ffs.adb
      
      # Set basic device information
      echo "6192" > strings/0x409/serialnumber
      echo "comma.ai" > strings/0x409/manufacturer
      echo "comma 3x" > strings/0x409/product
    fi

    # Mount functionfs for ADB
    mkdir -p /dev/usb-ffs/adb
    mount -o uid=2000,gid=2000 -t functionfs adb /dev/usb-ffs/adb
    mount -o remount,gid=5,mode=620 /dev/pts

    # Enable USB gadget
    if [ -d /sys/class/android_usb/android0 ]; then
      echo 1 > /sys/class/android_usb/android0/enable
    fi
    ;;

  stop)
    echo "Stopping USB Android Gadget"
    ;;

  restart)
    $0 stop
    $0 start
    ;;
  *)
    echo "Usage usb { start | stop | restart}" >&2
    exit 1
    ;;
esac

