#!/bin/bash
# Always restore the normal CPU cap, including failed or unmodified installs.
trap '/usr/comma/boot-cpu-cap.sh' EXIT
if [[ ! -f /data/openpilot/.agnos-early-ui || ! -f /data/openpilot/prebuilt ]]; then
  exit 0
fi
end=$((SECONDS+8))
while ((SECONDS < end)); do
  for frame in /tmp/boot-first-frame-*; do
    [[ -f "$frame" ]] && exit 0
  done
  sleep 0.02
done
exit 0
