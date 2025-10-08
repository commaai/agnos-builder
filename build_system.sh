#!/usr/bin/env bash
set -e

UBUNTU_BASE_URL="https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/"
UBUNTU_FILE="ubuntu-base-24.04.3-base-arm64.tar.gz"
UBUNTU_FILE_CHECKSUM="7b2dced6dd56ad5e4a813fa25c8de307b655fdabc6ea9213175a92c48dabb048"

# Make sure we're in the correct spot
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
cd $DIR

BUILD_DIR="$DIR/build"
OUTPUT_DIR="$DIR/output"

ROOTFS_DIR="$BUILD_DIR/agnos-rootfs"
ROOTFS_IMAGE="$BUILD_DIR/system.img"
OUT_IMAGE="$OUTPUT_DIR/system.img"

# the partition is 10G, but openpilot's updater didn't always handle the full size
# openpilot fix, shipped in 0.9.8 (8/18/24): https://github.com/commaai/openpilot/pull/33320
ROOTFS_IMAGE_SIZE=4500M

# Create temp dir if non-existent
mkdir -p $BUILD_DIR $OUTPUT_DIR

# Parallel download and checksum verification
download_and_verify() {
    if [ ! -f $UBUNTU_FILE ]; then
        echo -e "Downloading Ubuntu Base: $UBUNTU_FILE"
        if ! curl -C - -o $UBUNTU_FILE $UBUNTU_BASE_URL/$UBUNTU_FILE --silent --remote-time --fail --parallel --parallel-max 4; then
            echo "Download failed, please check Ubuntu releases: $UBUNTU_BASE_URL"
            exit 1
        fi
    fi
    
    # Check SHA256 sum
    if [ "$(shasum -a 256 "$UBUNTU_FILE" | awk '{print $1}')" != "$UBUNTU_FILE_CHECKSUM" ]; then
        echo "Checksum mismatch, please check Ubuntu releases: $UBUNTU_BASE_URL"
        exit 1
    fi
}

# Setup qemu and Docker buildx in parallel
setup_environment() {
    local pids=()
    
    # Setup qemu multiarch (background)
    if [ "$(uname -m)" = "x86_64" ]; then
        echo "Registering qemu-user-static"
        (docker run --rm --privileged multiarch/qemu-user-static --reset -p yes > /dev/null) &
        pids+=($!)
    fi
    
    # Enable BuildKit and check Dockerfile (background)
    export DOCKER_BUILDKIT=1
    (docker buildx build -f Dockerfile.agnos --check $DIR) &
    pids+=($!)
    
    # Wait for background tasks
    for pid in "${pids[@]}"; do
        wait $pid
    done
}

# Optimized Docker build with better caching
build_docker_images() {
    local build_args=(
        "--build-arg" "UBUNTU_BASE_IMAGE=$UBUNTU_FILE"
        "--platform=linux/arm64"
        "--cache-from=type=local,src=/tmp/docker-cache"
        "--cache-to=type=local,dest=/tmp/docker-cache,mode=max"
    )
    
    echo "Building agnos-builder docker image"
    BUILD="docker buildx build --load"
    if [ ! -z "$NS" ]; then
        BUILD="nsc build --load"
    fi
    
    # Build main image
    $BUILD -f Dockerfile.agnos -t agnos-builder $DIR "${build_args[@]}" &
    MAIN_BUILD_PID=$!
    
    # Build meta-builder in parallel
    echo "Building agnos-meta-builder docker image"
    docker buildx build --load -f Dockerfile.builder -t agnos-meta-builder $DIR \
        --build-arg UNAME=$(id -nu) \
        --build-arg UID=$(id -u) \
        --build-arg GID=$(id -g) \
        --cache-from=type=local,src=/tmp/docker-cache-meta \
        --cache-to=type=local,dest=/tmp/docker-cache-meta,mode=max &
    META_BUILD_PID=$!
    
    # Wait for main build
    wait $MAIN_BUILD_PID
    
    # Create main container
    echo "Creating agnos-builder container"
    CONTAINER_ID=$(docker container create --entrypoint /bin/bash agnos-builder:latest)
    
    # Wait for meta build
    wait $META_BUILD_PID
    
    # Start meta container
    echo "Starting agnos-meta-builder container"
    MOUNT_CONTAINER_ID=$(docker run -d --privileged -v $DIR:$DIR agnos-meta-builder)
}

# Optimized filesystem operations
create_and_mount_filesystem() {
    echo "Creating and mounting filesystem"
    
    # Pre-allocate and format in parallel with mounting preparation
    exec_as_user fallocate -l $ROOTFS_IMAGE_SIZE $ROOTFS_IMAGE &
    ALLOC_PID=$!
    
    exec_as_root mkdir -p $ROOTFS_DIR &
    MKDIR_PID=$!
    
    wait $ALLOC_PID
    wait $MKDIR_PID
    
    # Format filesystem
    exec_as_user mkfs.ext4 -F $ROOTFS_IMAGE &> /dev/null
    
    # Mount filesystem
    exec_as_root mount $ROOTFS_IMAGE $ROOTFS_DIR
}

# Optimized extraction with progress indication
extract_and_configure() {
    echo "Extracting docker image"
    
    # Export and extract in pipeline to avoid intermediate file
    docker container export $CONTAINER_ID | exec_as_root tar -xf - -C $ROOTFS_DIR &
    EXTRACT_PID=$!
    
    # Prepare network configuration function while extraction runs
    prepare_network_config() {
        cd $ROOTFS_DIR
        # Add hostname and hosts. This cannot be done in the docker container...
        HOST=comma
        ln -sf /proc/sys/kernel/hostname etc/hostname
        echo "127.0.0.1    localhost.localdomain localhost" > etc/hosts
        echo "127.0.0.1    $HOST" >> etc/hosts
        
        # Fix resolv config
        ln -sf /run/systemd/resolve/stub-resolv.conf etc/resolv.conf
        
        # Set capability for ping
        setcap cap_net_raw+ep bin/ping
        
        # Write build info
        DATETIME=$(date '+%Y-%m-%dT%H:%M:%S')
        printf "$GIT_HASH\n$DATETIME\n" > BUILD
    }
    
    # Wait for extraction to complete
    wait $EXTRACT_PID
    
    # Remove .dockerenv and configure network
    echo "Configuring system"
    exec_as_root rm -f $ROOTFS_DIR/.dockerenv
    
    echo "Setting network configuration"
    GIT_HASH=${GIT_HASH:-$(git --git-dir=$DIR/.git rev-parse HEAD)}
    exec_as_root bash -c "set -e; export ROOTFS_DIR=$ROOTFS_DIR GIT_HASH=$GIT_HASH; $(declare -f prepare_network_config); prepare_network_config"
}

# Optimized cleanup and finalization
finalize_image() {
    echo "Finalizing image"
    
    # Unmount filesystem
    exec_as_root umount -l $ROOTFS_DIR
    
    # Sparsify system image with progress
    exec_as_user img2simg $ROOTFS_IMAGE $OUT_IMAGE
    
    # Cleanup intermediate files
    rm -f $BUILD_DIR/filesystem.tar
}

# Define functions for docker execution
exec_as_user() {
    docker exec -u $(id -nu) $MOUNT_CONTAINER_ID "$@"
}

exec_as_root() {
    docker exec $MOUNT_CONTAINER_ID "$@"
}

# Enhanced cleanup function
cleanup() {
    echo "Cleaning up..."
    
    # Cleanup filesystem mount
    if [ ! -z "$MOUNT_CONTAINER_ID" ]; then
        exec_as_root umount -l $ROOTFS_DIR &> /dev/null || true
    fi
    
    # Cleanup containers
    if [ ! -z "$CONTAINER_ID" ]; then
        docker container rm -f $CONTAINER_ID &> /dev/null || true
    fi
    if [ ! -z "$MOUNT_CONTAINER_ID" ]; then
        docker container rm -f $MOUNT_CONTAINER_ID &> /dev/null || true
    fi
    
    # Kill any background processes
    jobs -p | xargs -r kill &> /dev/null || true
}

# Set trap for cleanup
trap cleanup EXIT

# Main execution flow
main() {
    echo "Starting optimized AGNOS build..."
    
    # Run initial tasks in parallel
    download_and_verify &
    DOWNLOAD_PID=$!
    
    setup_environment &
    SETUP_PID=$!
    
    # Wait for prerequisite tasks
    wait $DOWNLOAD_PID
    wait $SETUP_PID
    
    # Build Docker images (parallel internal)
    build_docker_images
    
    # Filesystem operations
    create_and_mount_filesystem
    
    # Extract and configure
    extract_and_configure
    
    # Finalize
    finalize_image
    
    echo "Build completed successfully!"
}

# Run main function
main "$@"