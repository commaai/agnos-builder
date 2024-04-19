#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
cd $DIR

TOOLS=$DIR/tools

if [ ! -d fc2x ]; then
  git clone ssh://git@git-master.quectel.com:8407/wifi.bt/fc2x.git
fi

cd fc2x
git reset --hard
git clean -xdff .
git apply $DIR/patch

export ARCH=arm64
export CROSS_COMPILE=$TOOLS/aarch64-linux-gnu-gcc/bin/aarch64-linux-gnu-
export CC=$TOOLS/aarch64-linux-gnu-gcc/bin/aarch64-linux-gnu-gcc
export LD=$TOOLS/aarch64-linux-gnu-gcc/bin/aarch64-linux-gnu-ld.bfd

mkdir -p WiFi/cnss_host_LEA/chss_proc/host/AIO/drivers/firmware/WLAN-firmware
mkdir -p WiFi/cnss_host_LEA/chss_proc/host/AIO/drivers/firmware/BT-firmware

cd WiFi/cnss_host_LEA/chss_proc/host/AIO/build
make drivers || make drivers

cd $DIR/fc2x
cp WiFi/cnss_host_LEA/chss_proc/host/AIO/rootfs-te-f30.build/lib/modules/wlan.ko $DIR/userspace/usr/comma/

mkdir -p $DIR/userspace/firmware/wlan/
cp ./WiFi/meta_build/load_meta/host/wlan_host/sdio/qcom_cfg.ini $DIR/userspace/firmware/wlan/

cp ./WiFi/meta_build/load_meta/wlan_firmware/sdio/*.bin $DIR/userspace/firmware/

cp ./WiFi/meta_build/load_meta/bdf/FC21SA-Q93/bdwlan30.bin $DIR/userspace/firmware/
