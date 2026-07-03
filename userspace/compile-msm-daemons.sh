#!/bin/bash
set -e

# Build linux-msm QRTR, rmtfs, tqftpserv, and pd-mapper for the AGNOS userspace image.

QRTR_VERSION="v1.2"
RMTFS_VERSION="v1.3"
TQFTPSERV_VERSION="v1.2"
PD_MAPPER_VERSION="v1.1"

STAGE_ROOT="/tmp/msm-daemons-root"
BUILD_ROOT="/tmp/msm-daemons-build"

export DEBIAN_FRONTEND=noninteractive

rm -rf "$STAGE_ROOT" "$BUILD_ROOT"
mkdir -p "$STAGE_ROOT" "$BUILD_ROOT"

apt-get update
apt-get install -yq --no-install-recommends \
  git \
  ca-certificates \
  build-essential \
  pkg-config \
  meson \
  ninja-build \
  libzstd-dev \
  libudev-dev \
  liblzma-dev \
  systemd-dev

# /usr/lib/aarch64-linux-gnu in the real (arm64) image build
MULTIARCH_LIBDIR="/usr/lib/$(dpkg-architecture -qDEB_HOST_MULTIARCH)"
export PKG_CONFIG_PATH="$MULTIARCH_LIBDIR/pkgconfig:/usr/lib/pkgconfig:/usr/share/pkgconfig:${PKG_CONFIG_PATH:-}"

cd "$BUILD_ROOT"

git clone -b "$QRTR_VERSION" --depth 1 https://github.com/linux-msm/qrtr
cd "$BUILD_ROOT/qrtr"
meson setup build --prefix=/usr --libdir="$MULTIARCH_LIBDIR"
ninja -C build
ninja -C build install
ldconfig
DESTDIR="$STAGE_ROOT" ninja -C build install

cd "$BUILD_ROOT"
git clone -b "$TQFTPSERV_VERSION" --depth 1 https://github.com/linux-msm/tqftpserv
cd "$BUILD_ROOT/tqftpserv"
meson setup build --prefix=/usr
ninja -C build
DESTDIR="$STAGE_ROOT" ninja -C build install

cd "$BUILD_ROOT"
git clone -b "$RMTFS_VERSION" --depth 1 https://github.com/linux-msm/rmtfs
cd "$BUILD_ROOT/rmtfs"
make
if ! make install prefix=/usr DESTDIR="$STAGE_ROOT"; then
  install -D -m 0755 ./rmtfs "$STAGE_ROOT/usr/bin/rmtfs"
fi
if [ ! -x "$STAGE_ROOT/usr/bin/rmtfs" ]; then
  install -D -m 0755 ./rmtfs "$STAGE_ROOT/usr/bin/rmtfs"
fi

cd "$BUILD_ROOT"
git clone -b "$PD_MAPPER_VERSION" --depth 1 https://github.com/linux-msm/pd-mapper
cd "$BUILD_ROOT/pd-mapper"
make
if ! make install prefix=/usr DESTDIR="$STAGE_ROOT"; then
  install -D -m 0755 ./pd-mapper "$STAGE_ROOT/usr/bin/pd-mapper"
fi
if [ ! -x "$STAGE_ROOT/usr/bin/pd-mapper" ]; then
  install -D -m 0755 ./pd-mapper "$STAGE_ROOT/usr/bin/pd-mapper"
fi

rm -rf \
  "${STAGE_ROOT:?}/usr/lib/systemd" \
  "${STAGE_ROOT:?}/usr/share" \
  "${STAGE_ROOT:?}/usr/include" \
  "${STAGE_ROOT:?}/usr/sbin"

find "$STAGE_ROOT" -type f \( -name "*.pc" -o -name "*.a" \) -delete

if [ -d "$STAGE_ROOT/usr/bin" ]; then
  find "$STAGE_ROOT/usr/bin" -mindepth 1 -maxdepth 1 ! \( \
    -name "rmtfs" \
    -o -name "tqftpserv" \
    -o -name "pd-mapper" \
    -o -name "qrtr-ns" \
    -o -name "qrtr-cfg" \
    -o -name "qrtr-lookup" \
  \) -exec rm -rf {} +
fi

if [ -d "$STAGE_ROOT/usr/lib" ]; then
  find "$STAGE_ROOT/usr/lib" \( -type f -o -type l \) ! -name "libqrtr.so*" -delete
fi

find "$STAGE_ROOT" -type d -empty -delete
find /tmp/msm-daemons-root -type f | sort
