#!/bin/bash -e

cd /tmp/weston
git clone -b display.lnx.7.8.r2-rel --depth 1 --single-branch https://git.codelinaro.org/clo/le/display/libgbm.git
cd libgbm

export WORKSPACE="/tmp/weston"

autoreconf --install

export CPPFLAGS="-D__user= -I/tmp/weston/include"

./configure --enable-compilewithdrm --with-glib

make install
# ls -al /tmp/weston/libgbm
# exit 1
