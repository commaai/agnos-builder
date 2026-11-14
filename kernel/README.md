# comma mainline kernel

The comma four (mici) and comma 3X (tizi), both SDM845, run a stable mainline
kernel with a small patch series. The Ubuntu base, system layout and Android
boot image format are those used by the rest of AGNOS.

## Layout

- `linux`: the linux-stable v7.3.1 tag, unmodified.
- `spectra`: the Spectra camera driver, built as an out-of-tree module. Its
  README covers where it came from.
- `patches`: `git format-patch` output, applied in order on top of `linux`.
  Each patch keeps its original author and, where one exists, links to its
  upstream submission.
- `dts`: `sdm845-comma-common.dtsi` holds the wiring shared by comma SDM845
  devices, `sdm845-comma-spectra.dtsi` the camera nodes, and each board has its
  own `.dts`. The bootloader picks the DTB whose `qcom,board-id` matches the
  device from those appended to the kernel, so one `boot.img` can serve every
  board listed in `DTBS` in `build_kernel.sh`.
- `configs/comma_defconfig`: `make savedefconfig` output, shared by every
  board. There's no udev to load modules for devices, so drivers are built in,
  except those that load firmware as they probe, before the root filesystem or
  `/firmware` would be mounted: the ADSP's `qcom_q6v5_pas`, Venus, and
  cfg80211, which reads `regulatory.db` once when it loads, with ath10k on top
  of it. `boot.sh` loads them, and the out-of-tree `spectra_camera`. The
  modem's `qcom_q6v5_mss` is built in, as it only loads firmware when rmtfs
  starts the modem.

## Build

```sh
./build_kernel.sh
./build_system.sh
```

`build_kernel.sh` exports the patched source to `build/linux` whenever the pin,
patches, DTS or config change, and builds out of tree in `build/kernel-out`,
so rebuilds are incremental. It produces `output/boot.img`, plus the
`output/kernel-modules/` and `output/linux-headers/` that `build_system.sh`
installs into the system image.

The modules, including `spectra_camera.ko`, ship in `system.img`, not
`boot.img`. Every build has the same release string (`7.3.1-agnos`), so a
kernel loads modules from another build without complaint. Flash `boot.img` and
`system.img` from the same build. `./flash_kernel.sh` on its own is only safe
when the kernel pin, patches and config are unchanged, e.g. after DTS-only
changes.

To change the config, run
`make ARCH=arm64 O=../kernel-out comma_defconfig menuconfig savedefconfig` in
`build/linux` and copy `../kernel-out/defconfig` to `kernel/configs/`.

## Camera

Upstream SDM845 CAMSS can capture the OS04C10 sensors as RAW12, but has no
ISP support. Until it does, the Spectra driver keeps openpilot's existing ISP
configuration, sensor tuning and camera ABI. It taints the kernel as an
out-of-tree module (4096).

## USB-C

The external port uses the Qualcomm gen1 Type-C TCPM backend (an upstream
RFC), DWC3 role switching and QMP orientation switching. It is a device to a
PC (ADB and NCM) and a host and 5 V source to peripherals such as the comma
eGPU dock. On shutdown, the port returns to sink mode. On the comma 3X the port
is sink-only until its wiring is checked against a schematic. The secondary USB
host connects the internal LTE modem.

## Power and reliability

The PMI8998 charger uses the upstream `qcom_smbx` driver. Neither board has a
battery: VBAT is regulated from the main supply, and the charger only takes
power from USB when its USBIN input is enabled. Writing `force-discharge` to
`/sys/class/power_supply/pmi8998-charger/charge_behaviour` suspends USBIN and
DCIN (the downstream `input_suspend`), so a USB host doesn't power the device;
`auto` resumes them, and every boot starts in `auto`. USBIN is also suspended
while the device sources VBUS on its USB-C port.

Reboots and panics are warm resets through PS_HOLD (`reboot=warm` plus
`qcom,no-firmware-warm-reset`: TZ has no PSCI warm reset), so ramoops keeps the
previous boot's console and crash logs in `/sys/fs/pstore`, as on the
downstream kernel. A panic reboots immediately.

Two devices never bind a driver: the GPU's GMU (msm drives it through the GPU)
and the crypto engine (QCE is not built). The GCC and GPU clock controllers
that supply them would wait for their `sync_state()` forever, and genpd would
keep every power domain that the bootloader left on powered for the whole
uptime (the downstream kernel turns them off). `fw_devlink.sync_state=timeout`
on the command line gives up on such consumers once deferred probing times
out, about 20 s into boot. Drop it once msm attaches a driver to the GMU
upstream.

The watchdog is the PM8998 PMIC watchdog (`pm8916_wdt`, max 127 s). The APSS
watchdog is disabled: TZ does not reset on its bite (it parks the CPU that
takes it, or goes to ramdump), and the downstream kernel has the same problem.
systemd arms the PMIC watchdog with a pretimeout and the panic governor. A
missed ping panics at the pretimeout, with the log in pstore. If no CPU takes
the bark (for example the one CPU that gets the SPMI interrupt is wedged with
interrupts off), the PMIC hard-resets at the timeout, without a pstore record.
The kernel stops the watchdog for power-off and for restarts into the
bootloader or EDL. During a plain reboot systemd keeps it armed
(`RebootWatchdogSec`), so a hang on the way down still resets.
