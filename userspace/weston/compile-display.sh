#!/bin/bash -e

cd /tmp/weston
mkdir -p hardware/qcom
git clone -b display.lnx.7.8.r2-rel --depth 1 --single-branch https://git.codelinaro.org/clo/la/platform/hardware/qcom/display.git hardware/qcom/display
export DISPLAY_PATH=/tmp/weston/hardware/qcom/display
cd $DISPLAY_PATH

export WORKSPACE="/tmp/weston"

autoreconf --install

# TODO: fix -D__user
# https://docs.kernel.org/kbuild/headers_install.html
export CPPFLAGS="-DPAGE_SIZE=4096 -D__user= -I/tmp/weston/include -I$DISPLAY_PATH/libdebug -I$DISPLAY_PATH/libdrmutils -I$DISPLAY_PATH/gpu_tonemapper -I$DISPLAY_PATH/sdm/include -I$DISPLAY_PATH/include -I/tmp/weston/libdrm -I/tmp/weston/libdrm/include/drm -I${WORKSPACE}/vendor/qcom/opensource/commonsys-intf/display/include"
export LDFLAGS="-L/tmp/weston/libdrm/build -L/tmp/weston/hardware/libhardware/modules/gralloc -L$DISPLAY_PATH/libdebug"

# uapi include files become the top level /usr/include/linux/ files
cp /usr/src/linux-headers-4.9.103+/include/uapi/media/msm_sde_rotator.h /tmp/weston/include/display/media
cp /usr/src/linux-headers-4.9.103+/include/uapi/linux/videodev2.h /tmp/weston/include/linux
cp /usr/src/linux-headers-4.9.103+/include/linux/compiler.h /tmp/weston/include/linux

./configure --enable-sdmhaldrm

make
