#!/bin/bash -e

apt-get install --no-install-recommends -yq g++-11

# https://github.com/commaai/agnos-builder/pull/188#issuecomment-1893380448
export CXX=g++-11
# Suppress warnings about deprecated declarations
export CXXFLAGS="-Wno-deprecated-declarations"
# TODO: remove no-deprecated-declarations and
# replace QImage::byteCount() with QImage::sizeInBytes(). This is a direct replacement as suggested by the deprecation message.
# replace QFontMetrics::width(QChar) with QFontMetrics::horizontalAdvance(QChar). This method is the recommended replacement for measuring the width of a character in the new versions of Qt.

# Build mapbox-gl-native
cd /tmp
# needs an include to compile on gcc 11
git clone --recursive https://github.com/andiradulescu/mapbox-gl-native.git
cd mapbox-gl-native
# removed commit pin
# git checkout 69f41ffff655ee28834c167ad1353112f370e6e5
mkdir build && cd build
cmake -DMBGL_WITH_QT=ON ..
make -j$(nproc) mbgl-qt
mv libqmapboxgl.so /tmp/libqmapboxgl.so
