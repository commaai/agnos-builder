#!/bin/bash -e
# SPIKE: collect the glibc runtime for the prebuilt glibc binaries (Qualcomm
# blobs, adbd, the Adreno graphics libs) so they run unmodified on Alpine.
# Everything lands under /usr/lib/aarch64-linux-gnu, which Ubuntu's ld.so
# searches before /usr/lib, so a glibc process never picks up a musl library.
# usage: glibc_island.sh <rootfs overlay> <out>
ROOT=$1
OUT=$2
ML=/usr/lib/aarch64-linux-gnu
mkdir -p "$OUT$ML" "$OUT/lib"

bins=$(find "$ROOT" /tmp/agnos/graphics -type f 2>/dev/null | while read -r f; do
  [ "$(head -c4 "$f" | tr -d '\0')" = $'\x7fELF' ] && readelf -d "$f" 2>/dev/null | grep -q 'libc.so.6' && echo "$f"
done)

# adbd's Android libcutils/liblog share SONAMEs with the Qualcomm ones, so
# resolve it without the overlay on the library path.
{
  for f in $bins; do
    LD_LIBRARY_PATH="$ROOT$ML:/tmp/agnos/graphics" ldd "$f" 2>/dev/null
  done
  ldd /tmp/agnos/adbd
} | awk '$2 == "=>" && $3 ~ /^\// { print $3 }' | sort -u | while read -r lib; do
  case "$lib" in
    "$ROOT"/*|/tmp/agnos/*) continue ;;  # shipped by the overlay/graphics stage already
  esac
  real=$(readlink -f "$lib")
  dst="$OUT$ML/${lib#$ML/}"
  case "$lib" in $ML/*) ;; *) dst="$OUT$ML/$(basename "$lib")" ;; esac
  mkdir -p "$(dirname "$dst")"
  cp -L "$real" "$dst"
done
cp -L /lib/ld-linux-aarch64.so.1 "$OUT/lib/ld-linux-aarch64.so.1"
find "$OUT" -type f | sort
du -sh "$OUT"
