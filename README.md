# agnos-builder

This is the tool to build AGNOS, our Ubuntu based OS. AGNOS runs on the [comma three devkit](https://comma.ai/shop/products/three).

NOTE: the `edk2_tici` and `agnos-firmware` submodules are internal, private repos.

## Setup

These tools are developed on and targeted for Ubuntu 20.04.

Run once to set things up:
```sh
git submodule update --init agnos-kernel-sdm845
./tools/extract_tools.sh
```

## Build the userspace

build:
```sh
./build_system.sh
```

load:
```sh
./flash_system.sh
```

## Build the kernel

build:
```sh
./build_kernel.sh
```

load:
```sh
# flash over fastboot
./flash_kernel.sh

# or load into running system via ssh
# ssh config needs host named 'tici'
./load_kernel.sh
```
