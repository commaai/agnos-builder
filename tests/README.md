# Boot resource stress

`stress_boot.py` starts bounded resource consumers as `comma` immediately after
`boot.service` completes. It reboots normally; SSH/ADB only deploys the test and
collects results. It temporarily replaces the openpilot launch with `/bin/true`,
leaving Wi-Fi and magic running. It uses the production app CPU group and limits.

Reserve UP devices using the comma-rack guide, save each JSON reservation response
in a private file, then run from the repository root:

```sh
python3 tests/stress_boot.py \
  --reservation /private/reservation-one.json \
  --reservation /private/reservation-two.json \
  --output /private/boot-results --boots 20
```

The driver first validates each consumer on the settled device. Each device cycles
through three profiles on separate boots:

* `immediate`: concurrent raw ALSA open/configure/prepare, KGSL/OpenCL context,
  non-master DRM buffer, filesystem/IPC, and input/FastRPC/ION/video access.
* `audio-clients`: replaces raw ALSA with fresh concurrent input/output PortAudio
  processes that stream silence/capture samples. No application initialization retries.
* `late-gpu`: delays the first graphics consumer by six seconds while other probes
  run. No DRM or camera consumer warms the GPU earlier in this profile.

Use `--camera --openpilot /data/openpilot` with a built checkout to also start
native camerad and encoderd in the first two profiles. Camera checks include the
first published frame, frame periods, cross-camera SOF alignment, and encoded
payload metadata. They do not decode the images or establish image quality.

The first failed use stops the fleet. Diagnostics/reinitialization never turn it
into a pass. Results retain boot IDs, monotonic timestamps, scheduling groups,
per-client logs, kernel waits, journal, and dmesg. Worker deadlines are bounded;
a kernel-stuck task is recorded rather than waited on indefinitely. Raw ALSA
preparation is distinct from PortAudio streaming, and FastRPC open/context creation
is not DSP model execution. This complements full onroad tests; it does not replace
their CAN, model, engagement, or sustained-load coverage.

The driver removes its hooks and restores the previously active comma service in
`finally`. The caller must keep reservations alive and release them after verifying
cleanup. If the host is interrupted, recover with:

```sh
sudo /usr/local/venv/bin/python /data/boot-resource-stress/test_boot_resources.py \
  uninstall --directory /data/boot-resource-stress
```

Uninstall verifies hook hashes and refuses to remove configuration changed by
someone else. Keep the reservation until recovery succeeds. Test files/results
under `/data/boot-resource-stress` remain for inspection.

Host regression checks:

```sh
python3 -m unittest discover -s tests -p 'test_*.py'
```

These check timeout/missing-result failures, delayed-GPU isolation, and camera
validation against the captured 50 ms phase-slip failure, including startup frames.
