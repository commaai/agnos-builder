#!/bin/sh
# Copyright (c) 2018 Qualcomm Technologies, Inc.
# All Rights Reserved.
# Confidential and Proprietary - Qualcomm Technologies, Inc.
#

set -e
echo -n "Starting cdsp: "

if [ -f /sys/kernel/boot_cdsp/boot ]; then
  echo 1 > /sys/kernel/boot_cdsp/boot
else
  echo "File not found! : /sys/kernel/boot_cdsp/boot"
fi

exit 0
