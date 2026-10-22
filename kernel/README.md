# mici mainline kernel

This builds only `sdm845-comma-mici.dtb`. The Ubuntu base, system layout and
Android boot-image format remain those used by AGNOS master.

## Sources

- `linux`: upstream Linux v7.3, commit
  `c03c1a14507dfaf8b856c2608f9ac216021fc222`.
- `spectra`: commaai/vamos, commit
  `7626c378c3d5762df673dd14d457631057779d27`. Only its
  `kernel/spectra-camera` source is built. Its README records the original
  Qualcomm camera source and the mainline port's provenance.
- `patches`: ordered Linux changes, applied with strict whitespace checks.
  Display, touch, SPI and Wi-Fi patches retain their original author headers.
  Camera clock/GPIO and Venus fixes extend the existing vamos approach.
- `dts`: the mici board, its common SDM845 wiring, and the retained Spectra
  camera nodes. There are three camera sensors; the unused fourth sensor and
  its supplies are omitted.

Both submodules stay unmodified. `build_kernel.sh` reconstructs generated
sources under `build/` when their pins or patches change, then merges
`configs/mici.config` into arm64 defconfig.

## Camera approach

Upstream SDM845 CAMSS can capture all three OS04C10 sensors as RAW12. It does
not yet provide the complete image-processing path used by openpilot. The
investigated IFE YUV/stats/parameters series targets newer VFE hardware, and
the OPE series targets a different processing block. This port reuses the
existing vamos Spectra driver to retain the production ISP/BPS configuration,
sensor tuning, exposure control and synchronization ABI.

The camera driver is a separate GPL module built against the exact kernel
output. Its expected out-of-tree taint bit is 4096; other taint bits, GPU
recoveries and kernel warnings still need investigation. Its UAPI headers are
installed with the kernel headers. Firmware remains the existing
`CAMERA_ICP.elf`; the UP's operating system is not part of the port.

## Build

```sh
git submodule update --init kernel/linux kernel/spectra
./build_kernel.sh
./build_system.sh
```

The build produces `output/boot.img`, `output/kernel-modules/`,
`output/linux-headers/` and `output/system.img`. The system-image build consumes
the matching headers and modules from the kernel build. Do not run the two
builds concurrently when preparing a release pair.

Qualcomm audio/video/camera modules load after the existing firmware mount.
Wi-Fi and Bluetooth UART drivers load as modules after the root filesystem is
available, so early firmware requests cannot fail before their files exist.
QRTR, remote storage and firmware file services replace the downstream
modem/Wi-Fi userspace daemons. Mesa and the pinned COMMA raylib build replace
the KGSL graphics runtime. Source pins and license notices are installed in
the resulting image.

The QRTR patches retain Igor Opaniuk's October 19, 2026 upstream
[HELLO-gate fixes](https://lore.kernel.org/all/20261019-upstream-qrtr-hello-gate-fix_b4-v1-0-bd420aec171b@oss.qualcomm.com/).
They preserve service announcements while a new remote endpoint is not ready
to receive its first HELLO. Losing those announcements on Linux 7.3 prevented
the modem from finding remote storage and caused repeated startup watchdogs.
Repeated cold and warm boots must verify modem and Wi-Fi readiness without
relying on recovery from an initial crash.

Per-device panel gamma curves are staged from `/persist/comma/dwo_gamma_curves`
before the first DRM modeset. The panel uses its defaults when calibration is
absent. Framebuffer console emulation is disabled so it cannot prepare the
panel before the calibration service runs.

## USB-C

Mici's external port uses the shared Qualcomm gen1 TCPM backend, DWC3 role
switching and QMP SuperSpeed orientation switching. Its dedicated PMI8998
VBUS regulator provides bounded source readiness, standard fault notifications
and shutdown cleanup; the internal modem remains on the secondary fixed host.
These drivers are built in for early ADB/NCM availability.

[USB provenance and testing](USB.md) records the upstream RFC, local changes,
42 fault scenarios and the remaining physical acceptance checks. Static review
and compilation do not establish source voltage, fault recovery, both cable
orientations or actual chestnut acceptance.

## Openpilot integration and testing

The matching local openpilot changes use MSM/IR3 tinygrad, DMA-BUF ownership
and CPU-access synchronization, standard Venus encoding/decoding, Mesa EGL,
and the mainline hardware interfaces. A stock KGSL/ION openpilot build is not
a validation target for this image. Companion changes are maintained locally
for review and transfer; this repository does not publish their PRs.

Use the AGNOS `TESTING.md` checklist in addition to openpilot's camera and
onroad tests. Validate repeated model/warp execution, camera restarts and
error recovery, segment drains, clip decoding, UI handoffs, power management,
boot/time/network readiness, and peripheral behavior. A single passing
onroad run is insufficient. Keep fixture limitations and stock failures
separate from mainline failures, and preserve logs from unsuccessful runs.

Flash and recover only the reserved DUT. Back up its boot images, system and
test state first; verify the active slot and image hashes. Never reflash the
UP. Do not hot-unbind the GPU, display controller or CAMCC during testing.
