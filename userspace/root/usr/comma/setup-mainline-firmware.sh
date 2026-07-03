#!/bin/bash
# Populate /usr/lib/firmware for the mainline kernel's modem/wifi bring-up.
#
# AGNOS mounts a rw tmpfs over /usr/lib/firmware at boot, so firmware shipped
# in the image there is hidden at runtime. This oneshot rebuilds the firmware
# tree from the factory /firmware partition (mounted by comma-init.sh) plus
# the two ath10k files vendored in the image at /usr/comma/firmware.
#
# Only runs on a mainline kernel (unit is gated on /sys/class/remoteproc);
# completely inert on the downstream 4.9 kernel.
set -e

FW=/usr/lib/firmware
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

# The qcom/sdm845 dir must exist even if empty: pd-mapper can crash on a
# missing firmware directory.
mkdir -p "$FW/qcom/sdm845" "$FW/ath10k/WCN3990/hw1.0"

# Modem boot chain: the mainline q6v5-mss driver requests qcom/sdm845/mba.mbn
# and qcom/sdm845/modem_nm.* while the factory partition names them
# modem.mdt / modem.b*.
ln -sf "$IMG/mba.mbn" "$FW/qcom/sdm845/mba.mbn"
ln -sf "$IMG/modem.mdt" "$FW/qcom/sdm845/modem_nm.mbn"
for seg in "$IMG"/modem.b*; do
  [[ -e "$seg" ]] || continue
  ln -sf "$seg" "$FW/qcom/sdm845/modem_nm.${seg##*/modem.}"
done

# Protection-domain maps for pd-mapper (the seven factory .jsn files).
for jsn in "$IMG"/*.jsn; do
  [[ -e "$jsn" ]] || continue
  ln -sf "$jsn" "$FW/qcom/sdm845/${jsn##*/}"
done

# WLAN firmware served to the modem by tqftpserv (re-rooted from the modem's
# /readonly/vendor/* requests via remoteproc firmware-dir discovery).
ln -sf "$IMG/wlanmdsp.mbn" "$FW/qcom/sdm845/wlanmdsp.mbn"

# ath10k host driver firmware: not present on the device, vendored in the
# image at a non-tmpfs path.
ln -sf "$VENDORED/ath10k/WCN3990/hw1.0/firmware-5.bin" "$FW/ath10k/WCN3990/hw1.0/firmware-5.bin"
ln -sf "$VENDORED/ath10k/WCN3990/hw1.0/board-2.bin" "$FW/ath10k/WCN3990/hw1.0/board-2.bin"

echo "mainline firmware tree populated in $FW"
