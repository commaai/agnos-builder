# agnos-builder

This is the buidler repo for AGNOS, our Ubuntu based OS. AGNOS runs on the comma three devkit and [comma 3X](https://comma.ai/shop/comma-3x).

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

## Contributing

Join us on [Discord](https://discord.comma.ai).

A comma 3/3X is helpful for working on AGNOS, but not required for a lot of interesting work.

AGNOS's main priority is to prove a stable platform to [openpilot](https://github.com/commaai/openpilot).
The second priority is to be a good platform for all sorts of [robotics development](https://blog.comma.ai/a-drive-in-the-office/).

### Roadmap

Some nice to haves:
* make the image tiny
* boot super fast
* update to Ubuntu 24.04 from 20.04
* use a mainline kernel for SnapDragon 845
* replace `agnos-firmware` will all open source
