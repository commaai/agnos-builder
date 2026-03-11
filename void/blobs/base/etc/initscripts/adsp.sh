#!/bin/sh
###############################################################################
#
# This script is used for System V init scripts to start adsp
#
# Copyright (c) 2012-2016 Qualcomm Technologies, Inc.
# All Rights Reserved.
# Confidential and Proprietary - Qualcomm Technologies, Inc.
#
###############################################################################

set -e

case "$1" in
  start)
        echo -n "Starting adsp: "
        /usr/local/qr-linux/adsp-start.sh 
        echo "done"
        ;;
  stop)
        echo -n "Stopping adsp: "
        echo 0 > /sys/kernel/boot_adsp/boot
        echo "done"
        ;;
  restart)
        $0 stop
        $0 start
        ;;
  *)
        echo "Usage adsp.sh { start | stop | restart}" >&2
        exit 1
        ;;
esac

exit 0
