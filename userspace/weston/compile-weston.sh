#!/bin/bash -e

cd /tmp/weston
git clone -b display.lnx.7.8.r2-rel --depth 1 --single-branch https://git.codelinaro.org/clo/le/wayland/weston.git
cd weston

git apply /tmp/weston/patches/weston/*.patch

DISPLAY_PATH=/tmp/weston/hardware/qcom/display
export CPPFLAGS="-w -D__GBM__ -I/tmp/weston/libdrm -I/tmp/weston/libdrm/include/drm -I/tmp/weston/vendor/qcom/opensource/commonsys-intf/display/include -I/tmp/weston/libgbm/inc -I$DISPLAY_PATH/sdm/include -I$DISPLAY_PATH/libdebug -I$DISPLAY_PATH/libdrmutils -I/tmp/weston/system/core/include"
export CXXFLAGS="-w -D__GBM__ -I$DISPLAY_PATH/include -I$DISPLAY_PATH/sdm"

export LDFLAGS="-Wl,--verbose -lcutils -lGLESv2_adreno -lEGL_adreno -lsdmutils -lsdmcore -ldrmutils -ldisplaydebug -L$DISPLAY_PATH/sdm/libs/core/.libs -L$DISPLAY_PATH/sdm/libs/utils/.libs -L$DISPLAY_PATH/libdrmutils/.libs -L/usr/lib/aarch64-linux-gnu/android -L/tmp/weston/libgbm/.libs -L$DISPLAY_PATH/libdebug/.libs"

# Fix /usr/bin/ld: cannot find -lliblog, since it should be -llog
sed -i "s/dep_log = cc.find_library('liblog', required : true)/dep_log = cc.find_library('log', required : true)/" /tmp/weston/weston/meson.build

# Fix issue with "DRM: does not support atomic modesetting" - commenting the assert to prevent segfault
sed -i '/assert(b->atomic_modeset);/s/^/\/\//' /tmp/weston/weston/libweston/backend-sdm/sdm.c

ln -sf libcutils.so.0.0.0 /usr/lib/aarch64-linux-gnu/libcutils.so && chown -h comma: /usr/lib/aarch64-linux-gnu/libcutils.so
ln -sf liblog.so.0.0.0 /usr/lib/aarch64-linux-gnu/liblog.so && chown -h comma: /usr/lib/aarch64-linux-gnu/liblog.so

# WESTON_DISABLE_ATOMIC - naive try - TODO: remove
# echo "config_h.set('WESTON_DISABLE_ATOMIC', '1')" >> /tmp/weston/weston/libweston/backend-sdm/meson.build

cp /tmp/weston/files/libweston/renderer-gl/*.* /tmp/weston/weston/libweston/renderer-gl/

meson setup -Dbackend-default=auto -Dbackend-rdp=false -Dpipewire=false -Dsimple-clients=all -Ddemo-clients=true -Dcolor-management-colord=false -Ddisable-power-key=true -Drenderer-gl=true -Dbackend-fbdev=false -Dbackend-headless=false -Dbackend-drm=false -Dweston-launch=false -Dcolor-management-lcms=false -Dmulti-display=false -Dpam=false -Dremoting=false -Dbackend-sdm=true -Dsystemd=false -Dlauncher-logind=false -Dbackend-drm-screencast-vaapi=false -Dbackend-wayland=false -Dimage-webp=false -Dbackend-x11=false -Dxwayland=false build #|| true

ninja -v -C build -j$(nproc)

checkinstall -yD --install=no --pkgname=weston ninja -v -C build -j$(nproc) install
mv weston*.deb /tmp/weston.deb
