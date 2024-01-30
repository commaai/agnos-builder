#!/bin/bash -e

cd /tmp/weston
mkdir -p hardware
git clone -b le-blast.lnx.1.4.r16-rel --depth 1 --single-branch https://git.codelinaro.org/clo/la/platform/hardware/libhardware.git hardware/libhardware
mkdir -p system
git clone -b le-blast.lnx.1.4.r16-rel --depth 1 --single-branch https://git.codelinaro.org/clo/la/platform/system/core.git system/core

cd hardware/libhardware

cd modules/gralloc

CC=gcc
CFLAGS="-DPAGE_SIZE=4096 -DLOG_TAG=\"gralloc\" -Wno-missing-field-initializers -I/tmp/weston/system/core/include -I/tmp/weston/hardware/libhardware/include"
LDFLAGS="-L/usr/lib/aarch64-linux-gnu/android"

SOURCES="gralloc.cpp framebuffer.cpp mapper.cpp"
OBJS=""
for src in $SOURCES; do
    obj="${src%.*}.o"
    OBJS="$OBJS $obj"
    echo "Compiling $src to $obj"
    $CC $CFLAGS -fPIC -c $src -o $obj
done

TARGET=libgralloc.so
$CC -shared -o $TARGET $OBJS $LDFLAGS
rm -f $OBJS
