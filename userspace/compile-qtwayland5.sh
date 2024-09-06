#!/bin/bash -e

# Patched qtwayland that outputs a fixed screen size
# Clone qtwayland submodule, checkout, apply patch, qmake, make
VERSION=5.12.9

cd /tmp
git clone --branch v${VERSION} --depth 1 https://github.com/qt/qtwayland.git
cd qtwayland

git apply /tmp/agnos/patch-qtwayland-v5.12

# qtwayland is incorrectly built against libdl.so instead of libdl.so.2
# https://stackoverflow.com/a/75855054/639708
ln -s libdl.so.2 /usr/lib/aarch64-linux-gnu/libdl.so

export DEBFULLNAME=comma
export LOGNAME=comma

dh_make --createorig -s -p qtwayland5_5.12.9 -y

echo -e "override_dh_usrlocal:" >> debian/rules
echo -e "override_dh_shlibdeps:\n\tdh_shlibdeps --dpkg-shlibdeps-params=--ignore-missing-info" >> debian/rules

DEB_BUILD_OPTIONS=nocheck dpkg-buildpackage -us -uc -nc

mv ../qtwayland5*.deb /tmp/qtwayland5.deb
