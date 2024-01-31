#!/bin/bash -e

cd /tmp/weston
git clone -b display.lnx.7.8.r2-rel --depth 1 --single-branch https://git.codelinaro.org/clo/le/wayland/weston.git
cd weston

git apply /tmp/weston/patches/weston/*.patch

DISPLAY_PATH=/tmp/weston/hardware/qcom/display
export CPPFLAGS="-w -I/tmp/weston/libdrm -I/tmp/weston/libdrm/include/drm -I/tmp/weston/vendor/qcom/opensource/commonsys-intf/display/include -I/tmp/weston/libgbm/inc -I$DISPLAY_PATH/sdm/include -I$DISPLAY_PATH/libdebug -I/tmp/weston/system/core/include -I$DISPLAY_PATH/libdrmutils -D__GBM__"
export CXXFLAGS="-w -I$DISPLAY_PATH/include -I$DISPLAY_PATH/sdm -D__GBM__"

export LDFLAGS="-Wl,--verbose -L$DISPLAY_PATH/sdm/libs/core/.libs -L$DISPLAY_PATH/sdm/libs/utils/.libs -L$DISPLAY_PATH/libdrmutils/.libs -L/usr/lib/aarch64-linux-gnu/android -L/tmp/weston/libgbm/.libs"

export PKG_CONFIG_PATH=/tmp/weston/libdrm/image/usr/local/lib/aarch64-linux-gnu/pkgconfig:$PKG_CONFIG_PATH

# Fix /usr/bin/ld: cannot find -lliblog, since it should be -llog
sed -i "s/dep_log = cc.find_library('liblog', required : true)/dep_log = cc.find_library('log', required : true)/" /tmp/weston/weston/meson.build

meson setup -Dbackend-default=auto -Dbackend-rdp=false -Dpipewire=false  -Dsimple-clients=all -Ddemo-clients=true -Dcolor-management-colord=false -Ddisable-power-key=true -Drenderer-gl=true -Dbackend-fbdev=false -Dbackend-headless=false -Dbackend-drm=false -Dweston-launch=false -Dcolor-management-lcms=false -Dmulti-display=false -Dpam=false -Dremoting=false -Dbackend-sdm=true -Dsystemd=false -Dlauncher-logind=false -Dbackend-drm-screencast-vaapi=false -Dbackend-wayland=false -Dimage-webp=false -Dbackend-x11=false -Dxwayland=false build #|| true

# cat /tmp/weston/weston/build/meson-logs/meson-log.txt
# ls -al /usr/lib/aarch64-linux-gnu/android
# exit 1

export DESTDIR='/tmp/weston/weston/image'
ninja -v -C build -j$(nproc) install

ls -al $DESTDIR
