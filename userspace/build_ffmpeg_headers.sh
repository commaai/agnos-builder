#!/bin/bash
set -euo pipefail

# comma-deps-ffmpeg 7.1.0.post98 ships libswscale.so.8 but omits its public
# headers. Supplement the matching FFmpeg 7.1 API without changing the library.
revision=b08d7969c550a804a59511c7b83f2dd8cc0499b8  # official n7.1 release
output=${FFMPEG_HEADERS_OUTPUT:-/tmp/agnos/ffmpeg-headers}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

for file in libswscale/swscale.h libswscale/version.h libswscale/version_major.h COPYING.LGPLv2.1; do
  mkdir -p "$work/$(dirname "$file")"
  curl --fail --location --retry 3 --silent --show-error \
    "https://raw.githubusercontent.com/FFmpeg/FFmpeg/$revision/$file" -o "$work/$file"
done

(cd "$work" && sha256sum --check <<'SUMS'
42ab58ed743efc74ba2152a049b521d41a0fae31595a9b9c6858742391570ca4  libswscale/swscale.h
35f3460f3be0ab1d9bab8735dbad97df71d4e6dbd46968c0e8c111714ce12a6e  libswscale/version.h
59377e8cf1cf5243456f800078d2d32d654552682ebfcae3c0a90b82a950fc56  libswscale/version_major.h
b634ab5640e258563c536e658cad87080553df6f34f62269a21d554844e58bfe  COPYING.LGPLv2.1
SUMS
)

install -d "$output/include/libswscale" "$output/share/doc/ffmpeg-headers"
install -m644 "$work/libswscale/"*.h "$output/include/libswscale/"
install -m644 "$work/COPYING.LGPLv2.1" "$output/share/doc/ffmpeg-headers/"
cat > "$output/share/doc/ffmpeg-headers/README" <<EOF_DOC
FFmpeg libswscale development header supplement

Source: https://github.com/FFmpeg/FFmpeg/tree/$revision
Version: official n7.1 release, commit $revision
License: LGPL-2.1-or-later; original notices remain in each header.

comma-deps-ffmpeg 7.1.0.post98 for aarch64 includes libswscale.so.8 but omits
these three public headers. They provide the matching FFmpeg 7.1 declarations
for Venus NV12 scaling; this supplement does not replace a runtime library.
Every downloaded header and the license are checked against pinned SHA256s.

Copy include/libswscale into the installed Python ffmpeg package's
install/include directory, as reported by ffmpeg.INCLUDE_DIR. On AGNOS this is:
/usr/local/venv/lib/python3.12/site-packages/ffmpeg/install/include/libswscale

Remove the supplement when comma-deps-ffmpeg ships its libswscale headers.
EOF_DOC
