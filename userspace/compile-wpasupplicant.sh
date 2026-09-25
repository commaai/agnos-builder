#!/bin/bash
set -e

# When bumping, update WPA_VERSION and the .dsc SHA256 below, then re-check
# patches against the new debian.tar.xz; Ubuntu may have backported them.
WPA_VERSION="2:2.10-21ubuntu0.4"

cd /tmp

apt-get update
WPA_CANDIDATE=$(LC_ALL=C apt-cache policy wpasupplicant | awk '$1 == "Candidate:" { print $2 }')
if [ -n "$WPA_CANDIDATE" ] && [ "$WPA_CANDIDATE" != "(none)" ] && \
   dpkg --compare-versions "$WPA_CANDIDATE" gt "$WPA_VERSION"; then
  echo "wpasupplicant candidate $WPA_CANDIDATE is newer than pinned $WPA_VERSION;" \
       "bump the source pin and re-check patches to avoid a final-stage downgrade." >&2
  exit 1
fi

apt-get install -yq --no-install-recommends \
      dpkg-dev \
      xz-utils

for file in "wpa_${WPA_VERSION#*:}.dsc" wpa_2.10.orig.tar.xz "wpa_${WPA_VERSION#*:}.debian.tar.xz"; do
  curl -fL --retry 3 -O "https://launchpad.net/ubuntu/+archive/primary/+files/$file"
done

# Pin the descriptor; dpkg-source verifies the source tarballs against it.
echo "08ebbe09f42de1b6602d43d267d8e20fa6fabbcf1477d42593b76769b4bf6211  wpa_${WPA_VERSION#*:}.dsc" | sha256sum -c -
dpkg-source -x "wpa_${WPA_VERSION#*:}.dsc" wpa
cd wpa

apt-get build-dep -yq --no-install-recommends -P pkg.wpa.nogui ./

for patch in /tmp/agnos/wpasupplicant/patches/*.patch; do
  cp "$patch" debian/patches/
  basename "$patch" >> debian/patches/series
done

cat > debian/changelog.agnos <<EOF
wpa (${WPA_VERSION}+agnos1) noble; urgency=medium

  * Backport SAE Rejected Groups length checks and the H2E token parser NULL
    pointer fix from hostap 2.11/2.12.
  * Require matching network context and AKMP for PMKSA cache entries
    (hostap advisory 2026-2).
  * Backport the SAE PT derivation check for SAE profiles (438a27b36).
  * Default global sae_pwe to 2, preserving overrides across SAVE_CONFIG
    and leaving D-Bus KeyMgmt reporting unchanged.

 -- AGNOS <agnos@localhost>  Fri, 25 Sep 2026 00:00:00 +0000

EOF
cat debian/changelog >> debian/changelog.agnos
mv debian/changelog.agnos debian/changelog

DEB_BUILD_OPTIONS="nocheck parallel=$(nproc)" dpkg-buildpackage -b -uc -us -Ppkg.wpa.nogui
mv ../wpasupplicant_*_arm64.deb /tmp/wpasupplicant.deb
