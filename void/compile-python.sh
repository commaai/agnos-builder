#!/bin/bash
set -e

# Build Python 3.12.7 from void-packages (last commit with 3.12.x before 3.13 upgrade)
# This replaces the xbps python3 3.14 package with 3.12.7
PYTHON_COMMIT=13b8dd2e9fab487721fcfcaf8e9791562f0ff4e8

# Clone latest void-packages, then checkout python3 template + python version config
# from the 3.12.7 era (can't checkout entire repo - old dependency versions conflict)
git clone --depth 1 https://github.com/void-linux/void-packages.git /tmp/void-packages
cd /tmp/void-packages
git fetch --depth 1 origin $PYTHON_COMMIT
git checkout FETCH_HEAD -- srcpkgs/python3 common/environment/setup/python.sh

# Use ethereal mode: Docker builds can't create namespaces/chroots
echo 'XBPS_CHROOT_CMD=ethereal' >> etc/conf
echo 'XBPS_ALLOW_RESTRICTED=yes' >> etc/conf

# Allow running as root inside Docker build
export XBPS_ALLOW_CHROOT_BREAKOUT=yes

# In ethereal mode, masterdir = root filesystem
ln -sf / masterdir
touch /.xbps_chroot_init

# bsdtar is needed by the python3 template's post_extract
xbps-install -Sy bsdtar || ln -sf /usr/bin/tar /usr/bin/bsdtar

./xbps-src binary-bootstrap
./xbps-src pkg python3

# Remove python3 3.14 packages that conflict with 3.12.7
# These are build-time deps pulled in by gdb/llvm/cmake - not needed at runtime
for pkg in $(xbps-query -l | grep python3- | awk '{print $2}' | sed 's/-[0-9].*//' | grep -v '^python3$'); do
    xbps-remove -Fy "$pkg" 2>/dev/null || true
done
# Remove packages that directly depend on python3 3.14
xbps-remove -Fy gi-docgen gdb 2>/dev/null || true
# Now remove python3 3.14 itself
xbps-remove -Fy python3 2>/dev/null || true

# Install our built python3 3.12.7 (skip python3-pip - it pulls in python3-3.14 from repo)
# pip is provided in the venv by uv's --seed flag
xbps-install -y -f --repository hostdir/binpkgs python3 python3-devel

# Reinstall gdb (will now depend on python3-3.12.7)
xbps-install -y gdb || true

# Ensure python3 points to 3.12 (not 3.14 if alternatives got confused)
ln -sf python3.12 /usr/bin/python3
ln -sf python3.12 /usr/bin/python

rm -f /.xbps_chroot_init
rm -rf /tmp/void-packages
