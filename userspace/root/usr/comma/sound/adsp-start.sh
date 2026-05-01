#!/bin/sh
###############################################################################
#
# This script is used for administration of the Hexagon DSP
#
# Copyright (c) 2012-2016 Qualcomm Technologies, Inc.
# All Rights Reserved.
# Confidential and Proprietary - Qualcomm Technologies, Inc.
#
###############################################################################

KEEP_ALIVE=0
subsys_name=""

echo -n "/firmware/image" > /sys/module/firmware_class/parameters/path

# Wait for adsp.mdt to show up
count=0
while [ ! -s /firmware/image/adsp.mdt ]; do
  sleep 0.1
  # wait 10s for /firmware mounted
  count=$(( $count + 1 ))
  if [ $count -ge 100 ]; then
    echo "[ERROR] Can not find the adsp's firmware"
    exit 1
  fi
done

for subsys in `ls /sys/bus/msm_subsys/devices`; do
  name=`cat /sys/bus/msm_subsys/devices/${subsys}/name`
  if [ "`cat /sys/bus/msm_subsys/devices/${subsys}/name`" = "adsp" ]; then
    subsys_name="${subsys}"
    break
  fi
done

if [ "$KEEP_ALIVE" = "1" ]; then
  if [ -n "${subsys_name}" ]; then
    sysctl -w kernel.panic=0
    echo 1 > /sys/bus/msm_subsys/devices/${subsys_name}/keep_alive
  else
    echo "[ERROR] Can not keep adsp alive"
  fi
fi

# FIXME: See ATL-3054
echo 1 > /sys/module/subsystem_restart/parameters/enable_debug
# Bring adsp out of reset
echo "[INFO] Bringing adsp out of reset"
echo "${subsys_name}"
echo 1 > /sys/kernel/boot_adsp/boot

# wait boot finished
if [ -n "${subsys_name}" ]; then
  count=0
  state=`cat /sys/bus/msm_subsys/devices/${subsys_name}/state`
  while [ "${state}" != "ONLINE" ]; do
    # wait 2s for subsys boot finished
    count=$(( $count + 1 ))
    if [ $count -ge 200 ]; then
      echo "[ERROR] adsp fail to boot"
      exit 1
    fi
    state=`cat /sys/bus/msm_subsys/devices/${subsys_name}/state`
    sleep 0.1
  done
fi

