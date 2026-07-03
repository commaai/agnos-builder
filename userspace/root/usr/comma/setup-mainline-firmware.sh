#!/bin/bash
# Populate /usr/lib/firmware for the mainline kernel's modem/wifi bring-up.
#
# The rootfs is mounted read-only, so the firmware tree can't be edited in
# place. Instead, build a symlink farm in /run that re-exposes everything the
# image already ships in /usr/lib/firmware, merges in the modem/wifi firmware
# from the factory /firmware partition (mounted by comma-init.sh) plus the two
# ath10k files vendored at /usr/comma/firmware, and bind-mount the farm over
# /usr/lib/firmware.
#
# Only runs on a mainline kernel (unit is gated on /sys/class/remoteproc);
# completely inert on the downstream 4.9 kernel.
set -e

FW=/usr/lib/firmware
ORIG=/run/firmware-orig
FARM=/run/mainline-firmware
IMG=/firmware/image
VENDORED=/usr/comma/firmware

# comma-init mounts /firmware; wait for the factory images to be visible.
for _ in $(seq 1 600); do
  [[ -s "$IMG/mba.mbn" ]] && break
  sleep 0.1
done
if [[ ! -s "$IMG/mba.mbn" ]]; then
  echo "timed out waiting for $IMG/mba.mbn" >&2
  exit 1
fi

# Idempotency across unit restarts: drop a previous farm bind before reading
# the original tree.
if mountpoint -q "$FW"; then
  umount "$FW"
fi

# Keep the image's original firmware reachable after the farm shadows $FW.
mkdir -p "$ORIG"
mountpoint -q "$ORIG" || mount --bind "$FW" "$ORIG"

rm -rf "$FARM"
mkdir -p "$FARM"

# Re-expose everything the image already ships (GPU, camera, wifi, ...).
for entry in "$ORIG"/*; do
  [[ -e "$entry" ]] || continue
  ln -s "$entry" "$FARM/${entry##*/}"
done

# Turn a re-exposed directory symlink back into a real (writable) directory
# whose contents are symlinks to the original entries, so we can merge our
# own files into it.
materialize() {
  local rel="$1"
  if [[ -L "$FARM/$rel" ]]; then
    rm "$FARM/$rel"
    mkdir "$FARM/$rel"
    local orig_entry
    for orig_entry in "$ORIG/$rel"/*; do
      [[ -e "$orig_entry" ]] || continue
      ln -s "$orig_entry" "$FARM/$rel/${orig_entry##*/}"
    done
  else
    mkdir -p "$FARM/$rel"
  fi
}

materialize qcom
materialize qcom/sdm845
materialize ath10k
materialize ath10k/WCN3990
materialize ath10k/WCN3990/hw1.0

# The kernel cmdline sets firmware_class.path=/lib/firmware/updates and
# pd-mapper errors out if that directory is missing.
mkdir -p "$FARM/updates"

# Modem boot chain: the mainline q6v5-mss driver requests qcom/sdm845/mba.mbn
# and qcom/sdm845/modem_nm.* while the factory partition names them
# modem.mdt / modem.b*.
ln -sf "$IMG/mba.mbn" "$FARM/qcom/sdm845/mba.mbn"
ln -sf "$IMG/modem.mdt" "$FARM/qcom/sdm845/modem_nm.mbn"
for seg in "$IMG"/modem.b*; do
  [[ -e "$seg" ]] || continue
  ln -sf "$seg" "$FARM/qcom/sdm845/modem_nm.${seg##*/modem.}"
done

# Protection-domain maps for pd-mapper (the seven factory .jsn files).
for jsn in "$IMG"/*.jsn; do
  [[ -e "$jsn" ]] || continue
  ln -sf "$jsn" "$FARM/qcom/sdm845/${jsn##*/}"
done

# WLAN firmware served to the modem by tqftpserv (re-rooted from the modem's
# /readonly/vendor/* requests via remoteproc firmware-dir discovery).
ln -sf "$IMG/wlanmdsp.mbn" "$FARM/qcom/sdm845/wlanmdsp.mbn"

# ath10k host driver firmware: not present on the device, vendored in the
# image at a non-tmpfs path.
ln -sf "$VENDORED/ath10k/WCN3990/hw1.0/firmware-5.bin" "$FARM/ath10k/WCN3990/hw1.0/firmware-5.bin"
ln -sf "$VENDORED/ath10k/WCN3990/hw1.0/board-2.bin" "$FARM/ath10k/WCN3990/hw1.0/board-2.bin"

mount --bind "$FARM" "$FW"

echo "mainline firmware tree populated in $FW"
