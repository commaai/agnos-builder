#!/bin/bash
set -e

FW=/usr/lib/firmware
ORIG=/run/firmware-orig
FARM=/run/mainline-firmware
IMG=/firmware/image
VENDORED=/usr/comma/firmware

for _ in $(seq 1 600); do
  [[ -s "$IMG/mba.mbn" ]] && break
  sleep 0.1
done
if [[ ! -s "$IMG/mba.mbn" ]]; then
  echo "timed out waiting for $IMG/mba.mbn" >&2
  exit 1
fi

if mountpoint -q "$FW"; then
  umount "$FW"
fi

mkdir -p "$ORIG"
mountpoint -q "$ORIG" || mount --bind "$FW" "$ORIG"

rm -rf "$FARM"
mkdir -p "$FARM"

for entry in "$ORIG"/*; do
  [[ -e "$entry" ]] || continue
  ln -s "$entry" "$FARM/${entry##*/}"
done

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

mkdir -p "$FARM/updates"

ln -sf "$IMG/mba.mbn" "$FARM/qcom/sdm845/mba.mbn"
ln -sf "$IMG/modem.mdt" "$FARM/qcom/sdm845/modem_nm.mbn"
for seg in "$IMG"/modem.b*; do
  [[ -e "$seg" ]] || continue
  ln -sf "$seg" "$FARM/qcom/sdm845/modem_nm.${seg##*/modem.}"
done

for jsn in "$IMG"/*.jsn; do
  [[ -e "$jsn" ]] || continue
  ln -sf "$jsn" "$FARM/qcom/sdm845/${jsn##*/}"
done

ln -sf "$IMG/wlanmdsp.mbn" "$FARM/qcom/sdm845/wlanmdsp.mbn"

ln -sf "$VENDORED/ath10k/WCN3990/hw1.0/firmware-5.bin" "$FARM/ath10k/WCN3990/hw1.0/firmware-5.bin"
ln -sf "$VENDORED/ath10k/WCN3990/hw1.0/board-2.bin" "$FARM/ath10k/WCN3990/hw1.0/board-2.bin"

mount --bind "$FARM" "$FW"

# same fixed mapping comma-init.sh uses for /dev/block/bootdevice/by-name
mkdir -p /dev/disk/by-partlabel
ln -sf /dev/sdf2 /dev/disk/by-partlabel/modemst1
ln -sf /dev/sdf3 /dev/disk/by-partlabel/modemst2
ln -sf /dev/sdf4 /dev/disk/by-partlabel/fsg
ln -sf /dev/sdf5 /dev/disk/by-partlabel/fsc
