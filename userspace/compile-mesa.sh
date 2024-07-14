#!/bin/bash -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"

# MESA_REPO="https://gitlab.freedesktop.org/mesa/mesa.git"
MESA_DIR="$DIR/mesa"
BUILD_DIR="build"
INSTALL_DIR="$DIR/mesa_install"
# INSTALL_DIR="/usr/local"
# INSTALL_DIR="$(mktemp -d)"
# https://gitlab.freedesktop.org/mesa/mesa/-/branches/all
# MESA_VERSION="23.3.0"
MESA_VERSION="24.0.5"
MESA_TAR="mesa-${MESA_VERSION}.tar.xz"
MESA_URL="https://archive.mesa3d.org/${MESA_TAR}"

LLVM_VERSION="17"

# Install dependencies
sudo apt update
sudo apt install -y \
    git \
    build-essential \
    meson \
    cmake \
    libglvnd-dev \
    libvdpau-dev \
    glslang-tools \
    libomxil-bellagio-dev \
    libva-dev \
    rustc \
    rustfmt \
    libclc-$LLVM_VERSION-dev \
    python3-mako \
    python3-pycparser \
    zlib1g-dev \
    libzstd-dev \
    libexpat1-dev \
    libbsd-dev \
    libdrm-dev \
    libudev-dev \
    llvm-$LLVM_VERSION-dev \
    libllvm$LLVM_VERSION \
    llvm-spirv-$LLVM_VERSION \
    libllvmspirvlib-$LLVM_VERSION-dev \
    clang-$LLVM_VERSION \
    libclang-$LLVM_VERSION-dev \
    libclang-cpp$LLVM_VERSION-dev \
    libelf-dev \
    valgrind \
    bison \
    byacc \
    flex \
    wayland-protocols \
    libwayland-dev \
    libwayland-egl-backend-dev \
    libxext-dev \
    libxfixes-dev \
    libxcb-glx0-dev \
    libxcb-shm0-dev \
    libx11-xcb-dev \
    libxcb-dri2-0-dev \
    libxcb-dri3-dev \
    libxcb-present-dev \
    libxshmfence-dev \
    libxxf86vm-dev \
    libxrandr-dev \
    bindgen \
    pkg-config
    # old deps
    # build-essential \
    # meson \
    # ninja-build \
    # libdrm-dev \
    # libx11-dev \
    # libxxf86vm-dev \
    # libxrandr-dev \
    # libxshmfence-dev \
    # libxdamage-dev \
    # libxext-dev \
    # libxfixes-dev \
    # libwayland-dev \
    # libglvnd-dev \
    # libelf-dev \
    # libunwind-dev \
    # libexpat1-dev \
    # libllvm-14-ocaml-dev \
    # libllvm14 \
    # llvm-14 \
    # llvm-14-dev \
    # llvm-14-runtime \
    # libclang-14-dev \
    # clang-14 \
    # libclang-cpp14-dev \
    # libvulkan-dev \
    # glslang-tools \
    # libzstd-dev \
    # libxcb-glx0-dev \
    # libxcb-shm0-dev \
    # libx11-xcb-dev \
    # libxcb-dri2-0-dev \
    # libxcb-dri3-dev \
    # libxcb-present-dev \
    # libxshmfence-dev \
    # libxxf86vm-dev \
    # libxrandr-dev \
    # libwayland-dev \
    # wayland-protocols \
    # libwayland-egl-backend-dev \
    # python3-mako \
    # libvdpau-dev

# if [ ! -d "$MESA_DIR" ]; then
#   git clone -b $MESA_VERSION_BRANCH --depth 1 --single-branch $MESA_REPO $MESA_DIR
#   cd $MESA_DIR
#   git apply $DIR/mesa-patches-$MESA_VERSION_BRANCH/*.patch
# fi

# Download and extract Mesa
if [ ! -d "$MESA_DIR" ]; then
    curl -L -o "$MESA_TAR" "$MESA_URL"
    tar -xf "$MESA_TAR"
    mv "mesa-${MESA_VERSION}" "$MESA_DIR"
    rm "$MESA_TAR"
    cd $MESA_DIR
    for patch in $DIR/mesa-patches-$MESA_VERSION/*.patch; do
      patch -p1 < "$patch"
    done
fi

cd $MESA_DIR

export CFLAGS="$CFLAGS -O2 -g1"
export CXXFLAGS="$CXXFLAGS -O2 -g1"
export CPPFLAGS="$CPPFLAGS -O2 -g1"

# Build Mesa with Freedreno and Rusticl support
# meson setup $BUILD_DIR --prefix=$INSTALL_DIR \
#     -Db_ndebug=true \
#     -Db_lto=true \
#     -Dgallium-drivers=freedreno \
#     -Dgallium-opencl=disabled \
#     -Dvulkan-drivers=freedreno \
#     -Dplatforms=wayland \
#     -Dglx=disabled \
#     -Dllvm=enabled \
#     -Dshared-llvm=enabled \
#     -Dgallium-rusticl=true \
#     -Drust_std=2021

meson setup $BUILD_DIR --prefix=$INSTALL_DIR \
    -Db_ndebug=true \
    -Db_lto=false \
    -Dgallium-drivers=freedreno \
    -Dgallium-opencl=disabled \
    -Dvulkan-drivers=freedreno \
    -Dplatforms=wayland \
    -Dglx=disabled \
    -Dllvm=enabled \
    -Dshared-llvm=enabled \
    -Dgallium-rusticl=true \
    -Drust_std=2021 \
    -Dgallium-va=disabled \
    -Dgallium-vdpau=disabled \
    -Dgallium-xa=disabled \
    -Dopengl=false \
		-Dosmesa=false \
    -Dgles1=disabled \
    -Dgles2=disabled \
    -Degl=disabled \
    -Dgallium-extra-hud=false \
    -Dgallium-nine=false
    # -Dvideo-codecs=disabled

ninja -C $BUILD_DIR

# mkdir -p $INSTALL_DIR/lib
sudo ninja -C $BUILD_DIR install

echo "Mesa $MESA_VERSION has been built and installed successfully to $INSTALL_DIR"
