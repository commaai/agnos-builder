# Spectra camera driver

The downstream Qualcomm Spectra (CAMSS v170) camera stack, ported to mainline
and built as one out-of-tree module, `spectra_camera.ko`. It provides the
request-manager, sync, sensor, ISP (IFE) and ICP ABI that openpilot's camerad
uses. Mainline CAMSS can only capture RAW, so this driver stays until mainline
has an ISP.

It was imported from commaai/vamos `7626c378c3d5` (`kernel/spectra-camera`).
Only the objects listed in `Kbuild` are built. The downstream Makefiles,
Kconfig and the unused AL6100 companion-ISP driver were dropped, and so was
every block openpilot's camerad never opens (see the git log).

- `spectra_module.c` registers the components in dependency order and
  unregisters them in reverse.
- `uapi/` holds the camera headers that `build_kernel.sh` installs into
  `output/linux-headers`. They are stored as `headers_install` output.
- The device tree nodes live in `../dts/sdm845-comma-spectra.dtsi`.
- `CONFIG_GPIO_SHARED` must stay off, because Spectra arbitrates its shared
  sensor GPIOs itself. The patch "gpio: allow disabling automatic shared GPIO
  ownership" makes it selectable.
- The ICP loads `CAMERA_ICP.elf` through the firmware loader.
