#!/bin/bash -e

# Install dependencies
sudo apt update
sudo apt install -y \
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
    libclc-17-dev \
    python3-mako \
    python3-pycparser \
    zlib1g-dev \
    libzstd-dev \
    libexpat1-dev \
    libbsd-dev \
    libdrm-dev \
    libudev-dev \
    llvm-17-dev \
    libllvm17 \
    llvm-spirv-17 \
    libllvmspirvlib-17-dev \
    clang-17 \
    libclang-17-dev \
    libclang-cpp17-dev \
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
    bindgen




    
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

# Variables
MESA_DIR="mesa"
BUILD_DIR="build"
INSTALL_DIR="/usr/local"
MESA_VERSION="24.1.2"
MESA_TAR="mesa-${MESA_VERSION}.tar.xz"
MESA_URL="https://archive.mesa3d.org/${MESA_TAR}"

# Download and extract Mesa
if [ ! -d "$MESA_DIR" ]; then
    curl -L -o "$MESA_TAR" "$MESA_URL"
    tar -xf "$MESA_TAR"
    mv "mesa-${MESA_VERSION}" "$MESA_DIR"
    rm "$MESA_TAR"
fi

# Build Mesa with Freedreno and Rusticl support
cd $MESA_DIR

meson setup $BUILD_DIR --prefix=$INSTALL_DIR \
    -Dgallium-drivers=freedreno \
    -Dvulkan-drivers=freedreno \
    -Dgallium-rusticl=true \
    -Dgallium-opencl=disabled \
    -Dllvm=enabled \
    -Drust_std=2021 \
    -Dplatforms=wayland \
    -Dopengl=false \
    -Dgallium-va=disabled \
    -Dgallium-vdpau=disabled \
    -Dgallium-xa=disabled \
    -Dgallium-nine=false \
    -Dosmesa=false
    # -Dglx=disabled \
    # -Degl=enabled \
    # -Dgbm=enabled \
    # -Dgles1=enabled \
    # -Dgles2=enabled \
    # -Dshared-glapi=enabled \
    # -Dgallium-extra-hud=true \
    # -Dgallium-nine=true \
    # -Dgallium-opencl=icd \
    # -Dopencl-spirv=true \
    # -Dosmesa=true
ninja -C $BUILD_DIR
# sudo ninja -C $BUILD_DIR install

echo "Mesa $MESA_VERSION has been built and installed successfully."
