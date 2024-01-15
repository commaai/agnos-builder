#!/bin/bash -e

# Build mapbox-gl-native
cd /tmp
git clone --recursive https://github.com/andiradulescu/mapbox-gl-native.git
cd mapbox-gl-native
# git checkout 69f41ffff655ee28834c167ad1353112f370e6e5
mkdir build && cd build
cmake -DMBGL_WITH_QT=ON ..
make -j$(nproc) mbgl-qt
mv libqmapboxgl.so /tmp/libqmapboxgl.so
