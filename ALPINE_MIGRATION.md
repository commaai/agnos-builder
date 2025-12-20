# Alpine Migration Plan (Draft 1)

## What We Have Today
- `build_system.sh` pulls `ubuntu-base-24.04.3-base-arm64.tar.gz`, loads it into `Dockerfile.agnos`, and bakes the final `system.img`.
- `Dockerfile.agnos` and `userspace/*.sh` assume Ubuntu/Debian tooling: `apt-fast`, `dpkg`, `.deb` blobs in `userspace/debs`, and systemd units in `userspace/files`.
- `Dockerfile.builder` is an Ubuntu 20.04 helper image that mounts the workspace and provides build-essential tools.
- Services are managed exclusively with systemd (`userspace/services.sh`), and dozens of `*.service`/`*.timer` files are copied into `/lib/systemd/system`.

The goal: swap the Ubuntu base for Alpine while keeping device functionality (openpilot, hardware services, flashing) unchanged.

## Guiding Principles
1. **Parallelize, don’t destabilize.** Leave the Ubuntu build path untouched; all Alpine work happens in new `build_alpine.sh`, `Dockerfile.alpine`, etc., until we prove parity.
2. **Change one layer at a time.** Migrate builder tooling before touching the rootfs so failures are easy to bisect.
3. **Stay reproducible.** Every replacement must be scripted (no manual `apk add` on a live device).
4. **Prefer rebuilding from source.** Debian-only `.deb` artifacts (qtwayland5, modemmanager, etc.) should become source builds or Alpine `apk`s.
5. **Keep service semantics.** Whether we keep systemd on Alpine or port to OpenRC must be decided up front and applied consistently.

## Phase A – Minimal Alpine Bring-up (Parallel Path)
Goal: produce a new `build_alpine.sh` that builds a tiny Alpine-based rootfs, flashes separately, boots to userspace, and runs `usr/comma/magic.py` to show the logo. Existing Ubuntu images/scripts remain the default.

1. [x] Create `Dockerfile.alpine` that starts from the Alpine minirootfs and installs just enough to boot OpenRC and launch the logo service.
2. [x] Clone `build_system.sh` into `build_alpine.sh`. Adjust it to:
   - Download `alpine-minirootfs-<ver>-aarch64.tar.gz`.
   - Use new Alpine docker build to produce a `system-alpine.img`.
   - Keep all outputs in `output/alpine/` so it doesn’t collide with Ubuntu artifacts.
3. [ ] Inside the Alpine image:
   - [x] Configure networking basics, hostname, and ensure `/usr/comma` is copied from the existing repository.
   - [x] Install just enough packages (`python3`, `py3-pip`, DRM/mesa bits) plus pip-install `pyray` for `magic.py`.
   - [x] Create an OpenRC service (`/etc/init.d/magic`) that launches `/usr/comma/magic.py` on boot and streams logs to `/var/log/magic.log`.
   - [ ] Validate on real hardware (or QEMU once GPU path is mocked) that the logo shows and backlight powers on.
4. [x] Add a simple smoke test stub (`test_alpine_magic.sh`) describing how to exercise the image until automation exists.
5. [ ] Document how to invoke the new flow in `README.md` (later) but keep it optional until feature-complete.

## Phase 0 – Recon & Prep
1. [ ] Pin an Alpine release (3.20 or edge) that ships `aarch64` and `armv7` repos; record mirror URLs.
2. [ ] List every Ubuntu package we install (`userspace/base_setup.sh`, `openpilot_dependencies.sh`, `install_extras.sh`, etc.) and mark whether Alpine has an equivalent `apk`, needs a community repo, or must be built from source.
3. [ ] Inventory `.deb` blobs in `userspace/debs`, `userspace/qtwayland`, compiler stages, and note which ones rely on glibc symbols.
4. [ ] Decide init strategy:
   - Option A: keep systemd (build it from source on Alpine + run in PID1).
   - Option B: switch to OpenRC (rewrite service units + helper scripts).
   Document the choice because it impacts almost every script.
5. [ ] Confirm musl vs glibc requirements. If any binary *must* stay glibc-linked (e.g., Qualcomm blobs), plan to add the `gcompat`/`alpine-pkg-glibc` shim or run those pieces inside a glibc sysroot.

## Phase 1 – Alpine Builder Container (new `Dockerfile.builder.alpine`)
1. [ ] Copy `Dockerfile.builder` to `Dockerfile.builder.alpine`; base the new file on `alpine:<version>` while leaving the Ubuntu original intact.
2. [ ] Swap `apt-get` for `apk add --no-cache` and install Alpine equivalents (`build-base`, `clang`, `openssl`, `ccache`, `android-tools`, `py3` packages, etc.).
3. [ ] Ensure `python2` requirement is gone or solved (Alpine only ships `python3`; if python2 is still needed, vendor it from source).
4. [ ] Re-implement the user-mapping logic using BusyBox `addgroup/adduser` syntax.
5. [ ] Verify `ccache` symlink setup still works and that `docker buildx --load` succeeds when `build_alpine.sh` references the new Dockerfile.

## Phase 2 – Alpine Rootfs Source (`build_alpine.sh`)
1. [ ] Copy `build_system.sh` to `build_alpine.sh` so the Ubuntu path remains unchanged.
2. [ ] Replace Ubuntu download variables with Alpine ones (use `alpine-minirootfs-<ver>-aarch64.tar.gz`) and update the SHA.
3. [ ] Wire `build_alpine.sh` to call the Alpine Dockerfile and emit outputs under `build/alpine/` + `output/alpine/`.
4. [ ] Drop `debconf`, `dpkg`, and `apt` assumptions as soon as the Alpine tarball is extracted; Alpine already has `apk-tools`.
5. [ ] Confirm `qemu-user-static` still handles musl binaries when running on x86_64 hosts.
6. [ ] Validate that `img2simg` + ext4 creation stays the same (filesystem layer is independent of distro).

## Phase 3 – Userspace & Package Installation (Alpine variants live beside Ubuntu)
1. **Agnos compiler stages**
   - [ ] Duplicate `Dockerfile.agnos` or split it into named targets so the Alpine build stages live alongside the Ubuntu ones without altering them.
   - [ ] Change all Alpine stages to `FROM alpine`. Install build deps via `apk` (`alpine-sdk`, `cmake`, `ninja`, etc.).
   - [ ] Audit `compile-*.sh` scripts for `apt-get`, `ldconfig`, `/usr/lib/aarch64-linux-gnu` assumptions; rewrite paths for Alpine (`/usr/lib`, `/lib`).
   - [ ] Replace `checkinstall`-generated `.deb` outputs with either plain tarballs or ad-hoc `.apk` packages (use `abuild` or `apkbuild` templates).
2. **Base setup (`userspace/base_setup.sh`)**
   - [ ] Add `userspace/base_setup_alpine.sh` (leave the Ubuntu script alone). Use `/etc/apk/repositories` plus `apk update && apk add`.
   - [ ] Recreate required system users/groups using BusyBox tools.
   - [ ] Re-map package names (e.g., `build-essential` → `build-base`, `network-manager` → `NetworkManager` from the community repo, `iptables-persistent` → `iptables` + manual save).
   - [ ] Handle 32-bit deps: Alpine’s `aarch64` repo does **not** support mixing `armhf` packages. Decide between cross-compiling needed 32-bit libs from source or hosting a parallel `armv7` sysroot mounted under `/lib32`.
   - [ ] Replace `locale-gen`/`update-locale` with Alpine equivalents (`/etc/profile.d/locale.sh`, `glibc-i18n` if using glibc shim, or `musl-locales`).
3. **Openpilot deps (`userspace/openpilot_dependencies.sh`, `openpilot_python_dependencies.sh`)**
   - [ ] Provide Alpine siblings of these scripts and translate each dependency to `apk` packages or source builds. For tools missing on Alpine, extend the compiler stages.
   - [ ] Ensure `uv` install script runs on musl (needs `build-base`, `curl`, `python3`).
4. **Hardware setup & proprietary debs**
   - [ ] For each `.deb` in `userspace/debs`, extract it (`dpkg-deb -x`) and repackage the payload into the Alpine rootfs manually or via custom `apk`s.
   - [ ] Verify Qualcomm binaries only depend on glibc symbols that exist in your shim (or keep a glibc chroot mounted under `/usr/glibc`).
   - [ ] Replace `apt install libjson-c2` hack with either an Alpine package or a source build pinned to the required ABI.
5. **Service management**
   - [ ] If staying with systemd: build systemd against musl (supported as of v253) and ensure `pam`, `udev`, and `resolved` pieces still work. Double-check `systemctl` invocations in `userspace/services.sh`.
   - [ ] If moving to OpenRC: convert every `.service`, `.timer`, `.path` file into OpenRC services; rewrite `userspace/services.sh` to call `rc-update`. Confirm replacements for `systemd-tmpfiles`, `journald`, and `networkd` (likely use `busybox-ntpd`, `rsyslog`, and `NetworkManager`).
6. **Filesystem layout differences**
   - [ ] Alpine does not use `/lib/systemd/system` or `/usr/lib/aarch64-linux-gnu`; adjust copy paths only in the Alpine Dockerfile variant.
   - [ ] Revisit `readonly_setup.sh`: drop `apt` cache cleanup, ensure `/etc/localtime` logic matches Alpine’s `/etc/TZ`/`/etc/timezone` expectations.

## Phase 4 – Image Assembly & Flash Scripts
1. [ ] Introduce `load_alpine*.sh` and `flash_alpine*.sh` companions instead of rewriting the Ubuntu scripts; point them at the new image names.
2. [ ] Ensure the Alpine image writes its own `/VERSION` metadata (maybe `VERSION_ALPINE` or embed in `VERSION`).
3. [ ] Re-run size optimization (Alpine is smaller; re-tune `ROOTFS_IMAGE_SIZE` specifically for the Alpine build).
4. [ ] Verify `readonly_setup.sh` + `mv /var /usr/default` still behave; Alpine may ship busybox `mv` without `-T`, so test carefully.

## Phase 5 – Validation
1. [ ] First milestone: boot the Alpine image and verify `/usr/comma/magic.py` auto-runs and shows the logo.
2. [ ] Full milestone: boot the new image on comma 3/3X; confirm kernel + modem + UI stack.
3. [ ] Run the existing `TESTING.md` checklist plus:
   - `apk` database integrity (`apk info -vv | head`).
   - Services status via the new init system.
   - Openpilot runtime smoke test.
4. [ ] Exercise flashing (`flash_alpine*.sh`) end-to-end on at least one device.
5. [ ] Document any remaining Ubuntu assumptions and either fix or log issues for follow-up.

## Open Questions & Risks
- **glibc-only blobs:** If Qualcomm or Weston hacks require glibc, we need either a glibc compatibility layer or to keep those pieces in a Debian chroot.
- **Systemd vs OpenRC:** Porting dozens of custom services may dwarf other work; validate effort before committing.
- **Multi-arch libraries:** Alpine currently lacks an easy way to install `armhf` packages alongside `aarch64`. Plan for source builds or rethink the need for 32-bit libs.
- **CI coverage:** GitHub Actions runners may not have `apk` tooling; ensure CI images are updated before merging.

> Next iteration: once we lock the init strategy and package availability, we can expand each checkbox into concrete scripts/commands.
