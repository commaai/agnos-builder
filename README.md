# agnos-builder

This is the builder repo for AGNOS, our Ubuntu based OS. AGNOS runs on the comma three devkit and [comma 3X](https://comma.ai/shop/comma-3x).

> [!NOTE]
> Use https://flash.comma.ai if you're looking to reflash your device to a clean factory state.

AGNOS includes all the software to boot and run a comma 3/3X.
This repo builds the two main parts of that (system and kernel) and packages it all up into a "release".

## Development

Any system that supports a recent [Docker](https://docs.docker.com/get-docker/) should work.

Run once to set things up:
```sh
git clone https://github.com/commaai/agnos-builder.git

cd agnos-builder
git submodule update --init agnos-kernel-sdm845
./tools/extract_tools.sh
```

Building
```
./build_kernel.sh
./build_system.sh
```

Flashing to a comma 3/3X:
```
./flash_kernel.sh
./flash_system.sh
```

Validating changes:
* Running openpilot is a good smoketest for general AGNOS functionality
* [CI](https://github.com/commaai/agnos-builder/blob/master/.github/workflows/build.yaml) ensures the kernel and system builds work (and pushes the images for you to download)
* [this](https://github.com/commaai/agnos-builder/blob/master/TESTING.md) is the checklist we go through before shipping new AGNOS releases to openpilot

### macOS

Building the kernel on macOS requires `agnos-builder` to be in a [Case-sensitive](https://support.apple.com/lv-lv/guide/disk-utility/dsku19ed921c/mac) filesystem.

Use this to set it up:
```
diskutil apfs addVolume <disk> "Case-sensitive APFS" agnos
```
* replace `<disk>` with the `synthesized` disk in `diskutil list` that includes your main volume (e.g. Macintosh HD) - usually `disk3` on M-series Macs, `disk1` on Intel Macs
* `agnos` is the name of the new volume - can be replaced with an arbitrary name
* the volume is mounted automatically in `/Volumes/agnos`

## Contributing

Join us in the `#dev-agnos` channel on [Discord](https://discord.comma.ai).

A comma 3/3X is helpful for working on AGNOS, but there's still lots of interesting work to do without one.

* [Discord](https://discord.comma.ai)
* [openpilot Docs](https://docs.comma.ai)
* [Bounties](https://comma.ai/bounties)

### Roadmap

AGNOS's main priority is to provide a stable platform to [openpilot](https://github.com/commaai/openpilot).
The second priority is to be a good platform for all sorts of [robotics development](https://blog.comma.ai/a-drive-in-the-office/).

Now that AGNOS is good at running openpilot, the next things up are:
* speedups: build system, CI, boot time, etc.
* cleanups: Android kernel to mainline kernel, simplify the build system, etc.
* open source: AGNOS started with a bunch blobs for various things, like the bootloaders and weston. We want to move everything we can to open source versions built in this repo.

Some concrete things on the roadmap:
- [ ] <10s boot time https://github.com/commaai/agnos-builder/issues/110, https://github.com/commaai/openpilot/issues/30894
- [ ] make the image tiny, for fast updating and flashing https://github.com/commaai/agnos-builder/issues/225
- [x] update to Ubuntu 24.04 https://github.com/commaai/openpilot/issues/32386
- [ ] mainline Linux kernel https://github.com/commaai/openpilot/issues/32386
- [ ] fully open source
  - [ ] anything from [firmware.json](firmware.json): XBL, ABL, etc.
  - [ ] Weston https://github.com/commaai/agnos-builder/issues/16
