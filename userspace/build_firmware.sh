#!/bin/bash
set -euo pipefail

# Unsigned firmware that the mainline drivers load from the root filesystem.
# Everything Qualcomm-signed for the device (MBA, MPSS, ADSP, Venus, wlanmdsp)
# stays on the modem partition, which the kernel searches first through
# firmware_class.path=/firmware/image, the same as stock.
output=/tmp/agnos/firmware
firmware=$output/usr/lib/firmware
doc=$output/usr/share/doc/agnos-firmware
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"

# Pinned so the image doesn't change when Ubuntu publishes an update. The
# archive drops superseded versions from the pool, so fall back to Launchpad,
# which keeps every published build.
version=20240318.git3b128b60-0ubuntu3.1
declare -A sha256=(
  [linux-firmware-qualcomm-graphics]=8a64c938780949a680214001a8b917d14444d9776e53b59bb73204fd6f7c297f
  [linux-firmware-qualcomm-wireless]=f333f7c1525949720b87e67dfee80e129ffff33d61fa97050428cd720392563c
)
files=(
  qcom/a630_sqe.fw qcom/a630_gmu.bin                  # GPU microcode
  ath10k/WCN3990/hw1.0/firmware-5.bin ath10k/WCN3990/hw1.0/board-2.bin
)

install -d "$doc"
for package in "${!sha256[@]}"; do
  deb=${package}_${version}_all.deb
  for url in "http://archive.ubuntu.com/ubuntu/pool/main/l/$package/$deb" \
             "https://launchpad.net/ubuntu/+archive/primary/+files/$deb"; do
    curl -fsSL -o "$deb" "$url" && break || rm -f "$deb"
  done
  echo "${sha256[$package]}  $deb" | sha256sum -c -
  dpkg-deb -x "$deb" root
  install -m644 "root/usr/share/doc/$package/copyright" "$doc/copyright.$package"
  echo "$package $version sha256:${sha256[$package]}" >> "$doc/SOURCES"
done

# Ubuntu compresses firmware with zstd, which the kernel isn't built to read.
for file in "${files[@]}"; do
  install -d "$firmware/$(dirname "$file")"
  zstd -q -d "root/lib/firmware/$file.zst" -o "$firmware/$file"
done

# The comma board data files aren't in linux-firmware yet. Add them to the
# board-2.bin container under the variants the devicetrees ask for.
bdencoder_revision=6e3ee2446a19e7f2b245b8d45174885d5c0614f0
curl -fsSLO "https://raw.githubusercontent.com/qca/qca-swiss-army-knife/$bdencoder_revision/tools/scripts/ath10k/ath10k-bdencoder"
echo "c4ae62fe60a94299f42186983ce17cb4ea6a067e743f79ca21f488ad5990567d  ath10k-bdencoder" | sha256sum -c -
for device in mici tizi; do
  python3 ath10k-bdencoder -a "$firmware/ath10k/WCN3990/hw1.0/board-2.bin" "/tmp/agnos/ath10k/comma-$device.bin" \
    "bus=snoc,qmi-board-id=ff,qmi-chip-id=30214,variant=comma-$device" > /dev/null
done
cat >> "$doc/SOURCES" <<EOF
qca-swiss-army-knife $bdencoder_revision ath10k-bdencoder, adding comma's board data:
  comma-mici: bdwlan.b01 from agnos-builder usr/comma/wlan, last changed in 94fc1d05
  comma-tizi: bdwlan.b00 from agnos-builder usr/comma/wlan, last changed in 0a49bcec
EOF
