# Comma four boot optimization experiment

Companion openpilot branch: `feature/fast-userspace-ui`, based on the tested device revision `0417b4f80`. This is an opt-in development profile for a prebuilt, fixed checkout. No reflash was used during device experiments.

## Retained changes

- Keep direct parallel mounts, GPIO and graphics permissions, the original power-supply test, and writable home/data setup before the UI. Await every mount result. The builder retains its DSP partition `/dev/sde9`; the older device image used `/dev/sde26`.
- Run UI import/render setup on CPU 5. Keep the startup CPU boost bounded by first frame or an eight-second timeout, restoring the normal 1689600 kHz cap, including failure/stop paths.
- Start the opted-in UI alongside the normal launcher. Keep D-Bus early because eager Settings needs it. Delay manager work until the first frame, with a five-second fallback.
- Move Qualcomm peripherals/audio/calibration after the UI gate, and maintenance/debug work to thirty-second timers. Normal background services resume at `basic.target`; first frame does not imply driving readiness.
- Read ahead the traced Python/native/font inputs while filesystems initialize. The manifest is specific to the tested venv and openpilot layout. Missing files are skipped; regenerate it when dependencies change. No cached font atlas is used.
- Retry boot-slot success marking after platform properties are available. Keep random-seed loading ordered after writable filesystem setup.

The newer builder already had direct mounts, lazy magic graphics and explicit GPIO permissions. Its monolithic `comma-init.sh` is split into essential/platform/debug modes here instead of copying the old device units. Its existing power test parameters and partition map are preserved. The resulting image has not been built/flashed or boot-measured; the device measurements below validate the older image's equivalent experiments, not this port.

## Enable on a matching development installation

After building openpilot and deploying its companion branch, create `/data/openpilot/prebuilt` and `/data/openpilot/.agnos-early-ui`. These flags are deliberately not created by the image builder. The early service declines pending OS upgrades, staged checkout swaps and reset triggers; remove the opt-in flag before updates or branch switches. Existing unpatched installations continue through the normal manager launch path.

The first-frame contract is `/tmp/boot-first-frame-PID`, written after `rl.end_drawing()`, and the manager uses `/run/openpilot-early-ui.pid`. Keep the companion changes together. To disable the experiment live, remove `.agnos-early-ui`, stop `openpilot-early-ui.service`, and restart the normal manager so it selects its normal UI process adapter.

## Measurements and rejected experiments

All values below subtract the kernel duration from the first completed UI frame. They are not full systemd startup durations.

| Configuration | Userspace to frame |
| --- | ---: |
| Prebuilt-only baseline | 12.983 s |
| Early services and deferred maintenance | 12.086 s |
| Direct mounts, explicit graphics permissions, lazy magic | 9.092 s |
| Big-core UI and first-frame priority | 5.894 s |
| Remove startup boost (rejected regression) | 6.788 s |
| Restore bounded boost; lazy settings | 5.141 s |
| Early UI and deferred HTTP/auth imports | 3.577 s |
| Supply-test overlap and deferred driving views | 3.240 s |
| Skip completed onboarding; native fonts | 2.974 s, repeat 2.980 s |
| File read-ahead and deferred WLAN | 2.658 s |
| NumPy/driving-alert import deferral (reverted) | 2.499 s |
| Concurrent read-ahead and manager wait, before rollback | 2.432 s |

The user ended the sub-two-second effort, requested removal of the NumPy/driving-alert changes, and reported first-tap Settings lag. Those import changes were reverted, and Settings now initializes eagerly. The user confirmed that Settings opens promptly. The final configuration differs from the faster measurements above.

Rejected entirely: reconstructed font-atlas caching, which broke text rendering. Original `rl.load_font_ex` was restored and the user confirmed normal fonts. No font-cache code is included in either branch.

## Validation

Shell syntax, read-ahead C compilation with warnings as errors, whitespace checks, and systemd dependency analysis are checked for this port. Local systemd analysis reports absent target-only executable paths; it does not substitute for a rootfs build and boot test. Release validation still needs the existing TESTING.md coverage, especially onroad operation, networking/modem, audio, reset and update paths. Do not infer those checks from successful offroad home/settings tests.

Final device reboot after reverting NumPy/driving-alert edits and restoring eager Settings: first frame `6.285725` seconds monotonic minus `2.952` seconds kernel = **3.333725 seconds userspace**. No failed services, no UI automatic restarts, CPU cap restored to `1689600`. This final responsiveness-first state is the one committed. The earlier 2.432-second experiment is not the committed result.
