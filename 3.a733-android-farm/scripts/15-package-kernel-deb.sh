#!/usr/bin/env bash
# Package the binder-enabled kernel as Debian .debs (Orange Pi's builddeb
# postinst runs mkimage -> /boot/uImage, which their boot.scr loads).
set -euo pipefail
source "$(dirname "$0")/env.sh"
# Orange Pi's builddeb reads a headers patch from a hard-coded /tmp path that
# orangepi-build normally drops there. Point it at our copy instead.
sed -i "s|patch -p1 < [^)]*headers-debian-byteshift.patch|patch -p1 < $FARM/config/headers-debian-byteshift.patch|" \
  "$KSRC/scripts/package/builddeb"
# BRANCH feeds the package name: linux-image-current-sun60iw2-redroid (next to stock)
rm -f "$FARM"/out/deploy/debs/*.deb
BRANCH=current make -C "$KSRC" -j"$JOBS" KDEB_PKGVERSION=1.0-redroid bindeb-pkg 2>&1 | tail -5
mkdir -p "$FARM/out/deploy/debs"
mv -v "$(dirname "$KSRC")"/linux-*.deb "$FARM/out/deploy/debs/"
rm -f "$FARM"/out/deploy/debs/*-dbg_*.deb   # 130 MB debug symbols, not needed on the board
rm -f "$(dirname "$KSRC")"/linux-*.{buildinfo,changes}
ls -la "$FARM/out/deploy/debs"
