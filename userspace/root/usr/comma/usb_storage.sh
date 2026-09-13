#!/bin/bash
set -euo pipefail

SOURCE=/data/media/0/realdata
SNAPSHOT=/data/tmp/usb-storage-snapshot
MOUNT=/run/usb-storage
IMAGE=$MOUNT/footage.img
GADGET=/config/usb_gadget/g1
LUN=$GADGET/functions/mass_storage.0/lun.0
UDC_STATE=/sys/class/udc/a600000.dwc3/state
ADB_PARAM=/data/params/d/AdbEnabled
OFFROAD_PARAM=/data/params/d/IsOffroad
LOCK=/run/comma-usb-gadget.lock
UDC=a600000.dwc3
# Stay above loggerd's 5 GiB / 10% deletion thresholds.
MIN_FREE_BYTES=$((6 * 1024 * 1024 * 1024))
MIN_FREE_PERCENT=11
FAT32_PAD_THRESHOLD=$((1280 * 1024 * 1024))
FAT32_MAX_FILE=$((4 * 1024 * 1024 * 1024 - 1))
# Current and legacy openpilot segment names.
SEGMENT_PATTERN='^([a-f0-9]{16}[|_])?([0-9]{4}-[0-9]{2}-[0-9]{2}--[0-9]{2}-[0-9]{2}-[0-9]{2}|[a-f0-9]{8}--[a-z0-9]{10})--[0-9]+$'
NBD_PID=

exec 9>"$LOCK"

attached() {
  local state=""
  IFS= read -r state 2>/dev/null < "$UDC_STATE" || true
  [[ "$state" == configured || "$state" == suspended ]]
}

mounted() {
  awk -v target="$MOUNT" '$5 == target { found=1 } END { exit !found }' \
    /proc/self/mountinfo
}

storage_enabled() {
  [[ ! -r "$ADB_PARAM" || "$(< "$ADB_PARAM")" != 1 ]]
}

offroad() {
  [[ -r "$OFFROAD_PARAM" && "$(< "$OFFROAD_PARAM")" == 1 ]]
}

space_available() {
  local block_size blocks available
  [[ -d "$SOURCE" && ! -L "$SOURCE" ]] || return 1
  read -r block_size blocks available <<< "$(stat -f -c '%S %b %a' "$SOURCE")"
  [[ "$block_size" =~ ^[0-9]+$ && "$blocks" =~ ^[0-9]+$ &&
     "$available" =~ ^[0-9]+$ ]] || return 1
  ((available * block_size > MIN_FREE_BYTES &&
    available * 100 > blocks * MIN_FREE_PERCENT))
}

ready() {
  storage_enabled && offroad && attached && space_available
}

clear_lun() {
  for _ in {1..50}; do
    { printf '\n' > "$LUN/file"; } 2>/dev/null || true
    [[ -z "$(< "$LUN/file")" ]] && return
    sleep 0.1
  done
  return 1
}

build_snapshot() {
  local cutoff segments=0 segment segment_name segment_id has_files
  local source_file file_name export_name size mtime
  rm -rf "$SNAPSHOT"
  install -d -m 0700 "$SNAPSHOT"
  printf 'PREFIX,SOURCE_SEGMENT\r\n' > "$SNAPSHOT/SEGMENTS.CSV"
  cutoff=$(($(date +%s) - 2))
  shopt -s nullglob

  for segment in "$SOURCE"/*; do
    [[ -d "$segment" && ! -L "$segment" ]] || continue
    segment_name=${segment##*/}
    [[ "$segment_name" =~ $SEGMENT_PATTERN ]] || continue
    compgen -G "$segment/*.lock" >/dev/null && continue
    ((segments < 999999)) || return 1
    segment_id=$(printf 'S%06d' "$((segments + 1))")
    has_files=0
    for source_file in "$segment"/*; do
      [[ -f "$source_file" && ! -L "$source_file" ]] || continue
      file_name=${source_file##*/}
      case "$file_name" in
        fcamera.hevc) export_name="${segment_id}F.265" ;;
        ecamera.hevc) export_name="${segment_id}W.265" ;;
        dcamera.hevc) export_name="${segment_id}C.265" ;;
        qcamera.ts) export_name="${segment_id}P.MTS" ;;
        rlog.zst) export_name="${segment_id}R.ZST" ;;
        qlog.zst) export_name="${segment_id}Q.ZST" ;;
        rlog.bz2) export_name="${segment_id}R.BZ2" ;;
        qlog.bz2) export_name="${segment_id}Q.BZ2" ;;
        *) continue ;;
      esac
      read -r size mtime <<< "$(stat -c '%s %Y' "$source_file")"
      ((size > 0 && size < FAT32_MAX_FILE && mtime <= cutoff)) || continue
      ln "$source_file" "$SNAPSHOT/$export_name" 2>/dev/null || continue
      has_files=1
    done
    if ((has_files)); then
      printf '%s,%s\r\n' "$segment_id" "$segment_name" >> "$SNAPSHOT/SEGMENTS.CSV"
      segments=$((segments + 1))
    fi
  done
  ((segments > 0)) || return 1
  printf '%s\r\n' \
    'COMMA FOOTAGE' \
    '' \
    'Read-only recordings from this device.' \
    'Files with the same S000001 prefix came from one segment.' \
    'SEGMENTS.CSV maps each prefix to its original route and segment.' \
    '' \
    'S000001P.MTS  road preview' \
    'S000001F.265  narrow road camera' \
    'S000001W.265  wide road camera' \
    'S000001C.265  cabin camera, when enabled' \
    'S000001R.ZST  route log (or .BZ2)' \
    'S000001Q.ZST  quick log (or .BZ2)' \
    '' \
    'Copy files to your computer, then eject COMMA before unplugging.' \
    > "$SNAPSHOT/READTHIS.TXT"
  echo "exporting $segments footage segments"
}

hex_at() {
  od -An -tx1 -N "$2" -j "$1" "$IMAGE" | tr -d ' \n'
}

patch_boot_sectors() {
  local base boot=$((2048 * 512))
  # Require an MBR with partition 1 starting at LBA 2048.
  [[ "$(hex_at 510 2)" == 55aa && "$(hex_at 454 4)" == 00080000 ]] || return 1
  # nbdkit 1.36 leaves the FAT32 boot jump and legacy BPB geometry zero;
  # normalize both boot copies in the private COW for host compatibility.
  for base in "$boot" "$((boot + 6 * 512))"; do
    printf '\xeb\x58\x90' | dd of="$IMAGE" bs=1 seek="$base" conv=notrunc status=none
    printf '\x3f\x00\xff\x00\x00\x08\x00\x00' | \
      dd of="$IMAGE" bs=1 seek=$((base + 24)) conv=notrunc status=none
    printf '\x80' | dd of="$IMAGE" bs=1 seek=$((base + 64)) conv=notrunc status=none
    [[ "$(hex_at "$base" 3)" == eb5890 ]] || return 1
  done
  sync -f "$IMAGE"
}

start_export() {
  local snapshot_size
  local -a size_arg=()
  snapshot_size=$(du -sbl "$SNAPSHOT" | cut -f1)
  if ((snapshot_size < FAT32_PAD_THRESHOLD)); then
    # Pad small snapshots to nbdkit's tested 2G FAT32 size. Above 1.25 GiB,
    # the plugin's natural image is already safely past the FAT32 threshold.
    size_arg=(size=2G)
  fi
  TMPDIR=/data/tmp /usr/bin/nbdfuse "$IMAGE" --command \
    /usr/bin/nbdkit -s --exit-with-parent --filter=cow floppy \
    "dir=$SNAPSHOT" label=COMMA "${size_arg[@]}" 9>&- &
  NBD_PID=$!
  for _ in {1..150}; do
    kill -0 "$NBD_PID" 2>/dev/null || return 1
    if mounted && [[ -f "$IMAGE" ]] &&
       (( $(stat -c %s "$IMAGE") > 1024 * 1024 * 1024 )); then
      patch_boot_sectors
      return
    fi
    sleep 0.1
  done
  return 1
}

clear_media() {
  local current=""
  flock 9
  if [[ -r "$LUN/file" ]]; then
    current="$(< "$LUN/file")"
    if [[ -n "$current" && "$current" != "$IMAGE" ]]; then
      echo "refusing to clear unexpected USB storage backing: $current" >&2
      [[ -z "$(< "$GADGET/UDC")" ]] || printf '\n' > "$GADGET/UDC"
      flock -u 9
      return 1
    fi
    if [[ -n "$current" ]]; then
      [[ -z "$(< "$GADGET/UDC")" ]] || printf '\n' > "$GADGET/UDC"
      clear_lun || { flock -u 9; return 1; }
      if storage_enabled; then
        sleep 1
        printf '%s\n' "$UDC" > "$GADGET/UDC"
      fi
    fi
  fi
  flock -u 9
}

insert_media() {
  flock 9
  storage_enabled || { flock -u 9; return 1; }
  [[ "$(< "$LUN/ro")" == 1 && "$(< "$LUN/removable")" == 1 &&
     "$(< "$GADGET/functions/mass_storage.0/stall")" == 1 &&
     -z "$(< "$LUN/file")" ]] || { flock -u 9; return 1; }
  [[ -z "$(< "$GADGET/UDC")" ]] || printf '\n' > "$GADGET/UDC"
  printf '%s\n' "$IMAGE" > "$LUN/file"
  [[ "$(< "$LUN/file")" == "$IMAGE" ]] || { flock -u 9; return 1; }
  sleep 1
  (storage_enabled && offroad && space_available) || {
    clear_lun || { flock -u 9; return 1; }
    if storage_enabled; then
      printf '%s\n' "$UDC" > "$GADGET/UDC"
    fi
    flock -u 9
    return 1
  }
  printf '%s\n' "$UDC" > "$GADGET/UDC"
  flock -u 9
}

stop_export() {
  local lazy=${1:-0}
  clear_media || return 1
  if [[ "$lazy" == 1 ]]; then
    umount --lazy --no-canonicalize "$MOUNT" 2>/dev/null || true
    ! mounted || return 1
  else
    for _ in {1..50}; do
      ! mounted && break
      umount "$MOUNT" 2>/dev/null || true
      sleep 0.1
    done
    ! mounted || return 1
  fi
  if [[ -n "$NBD_PID" ]]; then
    kill "$NBD_PID" 2>/dev/null || true
    wait "$NBD_PID" 2>/dev/null || true
  fi
  NBD_PID=
  rm -rf "$SNAPSHOT"
}

cleanup() {
  trap - EXIT
  stop_export || true
}

if [[ ${1:-} == cleanup ]]; then
  stop_export 1
  exit
fi
trap cleanup EXIT
trap 'exit 0' INT TERM
if [[ -d "$SNAPSHOT" ]] || mounted ||
   [[ -r "$LUN/file" && -n "$(< "$LUN/file")" ]]; then
  stop_export 1
fi
while ! ready; do
  sleep 1
done
if ! build_snapshot; then
  rm -rf "$SNAPSHOT"
  while storage_enabled && offroad && attached; do sleep 1; done
  trap - EXIT
  exit
fi
ready || exit 0
start_export
ready || exit 0
insert_media

for _ in {1..300}; do
  attached && break
  sleep 0.1
done
attached || exit 0
echo "USB footage ready"
reason=disconnect
while ready && kill -0 "$NBD_PID" 2>/dev/null && [[ -n "$(< "$LUN/file")" ]]; do
  sleep 1
done
if ready && [[ -z "$(< "$LUN/file")" ]]; then
  reason=eject
fi
stop_export
echo "USB footage stopped"
trap - EXIT

if [[ "$reason" == eject ]] && storage_enabled; then
  # Do not immediately reinsert media after the host ejects it.
  while attached; do sleep 1; done
fi
