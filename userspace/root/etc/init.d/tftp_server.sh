#! /bin/sh

### BEGIN INIT INFO
# Provides:          Qualcomm.com
# Required-Start:
# Required-Stop:
# Default-Start:
# Default-Stop:
# Short-Description: tftp server
# Description:       tftp server dasmon
### END INIT INFO
# Copyright (c) 2014 Qualcomm Technologies, Inc.  All Rights Reserved.
# Qualcomm Technologies Proprietary and Confidential.

set -e

case "$1" in
  start)
        echo -n "Starting tftp_server: "
        while [ ! -e /data/persist/rfs ] ; do sleep 0.1; done
        start-stop-daemon -S -b -x /sbin/tftp_server

        echo "done"
        ;;
  stop)
        echo -n "Stopping tftp_server: "
        start-stop-daemon -K -n tftp_server
        echo "done"
        ;;
  restart)
        $0 stop
        $0 start
        ;;
  *)
        echo "Usage tftp_server { start | stop | restart}" >&2
        exit 1
        ;;
esac

exit 0
