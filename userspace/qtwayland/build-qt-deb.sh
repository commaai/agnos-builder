#!/bin/bash
set -e

################################################################################
# Custom qt is created by combining qt packages from from Ubuntu 20.04 (focal)
# without getting into dependency hell.
################################################################################

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
TMP=$DIR/tmp
TMP_SRC=$TMP/qt-src-debs

# Create a new folder `qt-5.12.8` and put the metadata in
# `qt-5.12.8/DEBIAN/control`:

mkdir -p $TMP
cd $TMP
mkdir -p qt-5.12.8/DEBIAN

cat << EOF > qt-5.12.8/DEBIAN/control
Package: qt-focal
Version: 5.12.8
Architecture: all
Maintainer: Andrei Radulescu andi.radulescu@gmail.com
Depends: libicu66 (>= 66.1-1~), libdouble-conversion3 (>= 2.0.0), libssl1.1
Replaces: qtbase5-dev, qtchooser, qt5-qmake, qtbase5-dev-tools
Installed-Size: 0
Homepage: https://comma.ai
Description: Qt 5.12.8 from Ubuntu 20.04
EOF

# Download the official debs:
mkdir -p $TMP_SRC
cd $TMP_SRC

curl -sSLO https://launchpad.net/ubuntu/+archive/primary/+files/qtbase5-dev_5.12.8+dfsg-0ubuntu2.1_arm64.deb
curl -sSLO https://launchpad.net/ubuntu/+archive/primary/+files/qtbase5-dev-tools_5.12.8+dfsg-0ubuntu2.1_arm64.deb
curl -sSLO https://launchpad.net/ubuntu/+archive/primary/+files/qtbase5-private-dev_5.12.8+dfsg-0ubuntu2.1_arm64.deb

curl -sSLO https://launchpad.net/ubuntu/+archive/primary/+files/qt5-qmake_5.12.8+dfsg-0ubuntu2.1_arm64.deb
curl -sSLO https://launchpad.net/ubuntu/+archive/primary/+files/qt5-qmake-bin_5.12.8+dfsg-0ubuntu2.1_arm64.deb

curl -sSLO https://launchpad.net/ubuntu/+archive/primary/+files/qtdeclarative5-dev-tools_5.12.8-0ubuntu1_arm64.deb

curl -sSLO https://launchpad.net/ubuntu/+archive/primary/+files/libqt5core5a_5.12.8+dfsg-0ubuntu2.1_arm64.deb
curl -sSLO https://launchpad.net/ubuntu/+archive/primary/+files/libqt5network5_5.12.8+dfsg-0ubuntu2.1_arm64.deb
curl -sSLO https://launchpad.net/ubuntu/+archive/primary/+files/libqt5gui5_5.12.8+dfsg-0ubuntu2.1_arm64.deb
curl -sSLO https://launchpad.net/ubuntu/+archive/primary/+files/libqt5dbus5_5.12.8+dfsg-0ubuntu2.1_arm64.deb
curl -sSLO https://launchpad.net/ubuntu/+archive/primary/+files/libqt5printsupport5_5.12.8+dfsg-0ubuntu2.1_arm64.deb
curl -sSLO https://launchpad.net/ubuntu/+archive/primary/+files/libqt5test5_5.12.8+dfsg-0ubuntu2.1_arm64.deb
curl -sSLO https://launchpad.net/ubuntu/+archive/primary/+files/libqt5concurrent5_5.12.8+dfsg-0ubuntu2.1_arm64.deb
curl -sSLO https://launchpad.net/ubuntu/+archive/primary/+files/libqt5widgets5_5.12.8+dfsg-0ubuntu2.1_arm64.deb
curl -sSLO https://launchpad.net/ubuntu/+archive/primary/+files/libqt5xml5_5.12.8+dfsg-0ubuntu2.1_arm64.deb

curl -sSLO https://launchpad.net/ubuntu/+archive/primary/+files/libqt5opengl5-dev_5.12.8+dfsg-0ubuntu2.1_arm64.deb
curl -sSLO https://launchpad.net/ubuntu/+archive/primary/+files/libqt5opengl5_5.12.8+dfsg-0ubuntu2.1_arm64.deb

curl -sSLO https://launchpad.net/ubuntu/+archive/primary/+files/libqt5sql5-sqlite_5.12.8+dfsg-0ubuntu1_arm64.deb
curl -sSLO https://launchpad.net/ubuntu/+archive/primary/+files/libqt5sql5_5.12.8+dfsg-0ubuntu2.1_arm64.deb

curl -sSLO https://launchpad.net/ubuntu/+archive/primary/+files/libqt5svg5-dev_5.12.8-0ubuntu1_arm64.deb
curl -sSLO https://launchpad.net/ubuntu/+archive/primary/+files/libqt5svg5_5.12.8-0ubuntu1_arm64.deb

curl -sSLO https://launchpad.net/ubuntu/+archive/primary/+files/libqt5multimedia5-plugins_5.12.8-0ubuntu1_arm64.deb
curl -sSLO https://launchpad.net/ubuntu/+archive/primary/+files/libqt5multimedia5_5.12.8-0ubuntu1_arm64.deb
curl -sSLO https://launchpad.net/ubuntu/+archive/primary/+files/libqt5multimediagsttools5_5.12.8-0ubuntu1_arm64.deb
curl -sSLO https://launchpad.net/ubuntu/+archive/primary/+files/libqt5multimediawidgets5_5.12.8-0ubuntu1_arm64.deb

curl -sSLO https://launchpad.net/ubuntu/+archive/primary/+files/qml-module-qtquick2_5.12.8-0ubuntu1_arm64.deb
curl -sSLO https://launchpad.net/ubuntu/+archive/primary/+files/libqt5qml5_5.12.8-0ubuntu1_arm64.deb
curl -sSLO https://launchpad.net/ubuntu/+archive/primary/+files/qt5-qmltooling-plugins_5.12.8-0ubuntu1_arm64.deb

curl -sSLO https://launchpad.net/ubuntu/+archive/primary/+files/qtdeclarative5-dev_5.12.8-0ubuntu1_arm64.deb
curl -sSLO https://launchpad.net/ubuntu/+archive/primary/+files/qtdeclarative5-private-dev_5.12.8-0ubuntu1_arm64.deb

curl -sSLO https://launchpad.net/ubuntu/+archive/primary/+files/qtlocation5-dev_5.12.8+dfsg-0ubuntu1_arm64.deb
curl -sSLO https://launchpad.net/ubuntu/+archive/primary/+files/libqt5location5_5.12.8+dfsg-0ubuntu1_arm64.deb
curl -sSLO https://launchpad.net/ubuntu/+archive/primary/+files/libqt5location5-plugins_5.12.8+dfsg-0ubuntu1_arm64.deb
curl -sSLO https://launchpad.net/ubuntu/+archive/primary/+files/libqt5location5-plugin-mapboxgl_5.12.8+dfsg-0ubuntu1_arm64.deb

curl -sSLO https://launchpad.net/ubuntu/+archive/primary/+files/qtmultimedia5-dev_5.12.8-0ubuntu1_arm64.deb
curl -sSLO https://launchpad.net/ubuntu/+archive/primary/+files/libqt5multimedia5_5.12.8-0ubuntu1_arm64.deb
curl -sSLO https://launchpad.net/ubuntu/+archive/primary/+files/libqt5multimediaquick5_5.12.8-0ubuntu1_arm64.deb

curl -sSLO https://launchpad.net/ubuntu/+archive/primary/+files/qtpositioning5-dev_5.12.8+dfsg-0ubuntu1_arm64.deb
curl -sSLO https://launchpad.net/ubuntu/+archive/primary/+files/libqt5positioning5_5.12.8+dfsg-0ubuntu1_arm64.deb
curl -sSLO https://launchpad.net/ubuntu/+archive/primary/+files/libqt5positioningquick5_5.12.8+dfsg-0ubuntu1_arm64.deb
curl -sSLO https://launchpad.net/ubuntu/+archive/primary/+files/libqt5positioning5-plugins_5.12.8+dfsg-0ubuntu1_arm64.deb

curl -sSLO https://launchpad.net/ubuntu/+archive/primary/+files/libqt5quick5_5.12.8-0ubuntu1_arm64.deb
curl -sSLO https://launchpad.net/ubuntu/+archive/primary/+files/libqt5quickwidgets5_5.12.8-0ubuntu1_arm64.deb
curl -sSLO https://launchpad.net/ubuntu/+archive/primary/+files/libqt5quicktest5_5.12.8-0ubuntu1_arm64.deb
curl -sSLO https://launchpad.net/ubuntu/+archive/primary/+files/libqt5quickshapes5_5.12.8-0ubuntu1_arm64.deb
curl -sSLO https://launchpad.net/ubuntu/+archive/primary/+files/libqt5quickparticles5_5.12.8-0ubuntu1_arm64.deb

curl -sSLO https://launchpad.net/ubuntu/+archive/primary/+files/libqt5waylandclient5_5.12.8-0ubuntu1_arm64.deb
curl -sSLO https://launchpad.net/ubuntu/+archive/primary/+files/libqt5waylandcompositor5_5.12.8-0ubuntu1_arm64.deb

curl -sSLO https://launchpad.net/ubuntu/+archive/primary/+files/qtwayland5_5.12.8-0ubuntu1_arm64.deb

curl -sSLO https://launchpad.net/ubuntu/+archive/primary/+files/qt5-default_5.12.8+dfsg-0ubuntu2.1_arm64.deb

curl -sSLO https://launchpad.net/ubuntu/+archive/primary/+files/qtchooser_66-2build1_arm64.deb

# And unpack them:
for deb in *.deb; do dpkg-deb -R "$deb" "${deb%.deb}"; done

# Copy all files in qt-5.12.8
cd $TMP
cp -a $TMP_SRC/*/usr qt-5.12.8

# Package the deb and clean up everything else
dpkg-deb --root-owner-group --build "qt-5.12.8" "qt-5.12.8.deb"
mv qt-5.12.8.deb $DIR
rm -rf qt-5.12.8 $TMP_SRC
