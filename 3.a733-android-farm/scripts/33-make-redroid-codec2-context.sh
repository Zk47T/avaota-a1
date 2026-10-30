#!/usr/bin/env bash
# Hardware video for Route A: layer Allwinner's Codec2 HAL (c2.allwinner.*,
# CedarC 2.0.12) on top of redroid-pvr:13. Taken from Orange Pi's official
# Zero 3W Android 13 image, whose GPU blobs are byte-identical to Route A's
# (DDK 24.2@6643903), so its gralloc handles follow the sunxi layout the HAL
# expects (data[0] = dma-buf, data[1] = metadata). README section 17.
# Needs curl, tar, python3; pyelftools for the link check (same as script 26).
set -euo pipefail
source "$(dirname "$0")/env.sh"
IMG_ID=1pkdnQSufB3uY3vTj3uskWLsNV8w7cPD1      # Orange Pi Drive, "Android Image" folder
IMG_TGZ=OrangePiZero3W_A733_Android13_v1.0.tar.gz
IMG_SHA=8081ff479cb1e621a09ada104cb0b865325b559dae76e0a2f5f46ceffe606c4d
CACHE=$FARM/out/cache/opi-android
V=$CACHE/z3w-a13/vendor
ROOT=$FARM/out/cache/redroid-13.0.0_64only-240527/root
C=$FARM/out/redroid-pvr-c2
SVC=android.hardware.media.aw.c2@1.0-service

if [ ! -f "$V/bin/hw/$SVC" ]; then
  mkdir -p "$CACHE"
  [ -f "$CACHE/$IMG_TGZ" ] || curl -L --fail -o "$CACHE/$IMG_TGZ" \
    "https://drive.usercontent.google.com/download?id=$IMG_ID&export=download&confirm=t"
  echo "$IMG_SHA  $CACHE/$IMG_TGZ" | sha256sum -c -
  T=$(mktemp -d "$CACHE/unpack.XXXX")
  tar xzf "$CACHE/$IMG_TGZ" -C "$T"
  python3 -I "$FARM/scripts/aw_android_image.py" extract "$T"/*.img "$T/out" vendor_a vendor_dlkm_a
  rm -rf "$CACHE/z3w-a13"; mkdir -p "$CACHE/z3w-a13"
  mv "$T/out/vendor_a" "$V"; mv "$T/out/vendor_dlkm_a" "$CACHE/z3w-a13/vendor_dlkm"
  rm -rf "$T"
fi
B=$FARM/src/android-gpu/img-rgx/bxm/arm64/lib64
if [ -f "$B/libsrv_um.so" ]; then
  cmp -s "$V/lib64/libsrv_um.so" "$B/libsrv_um.so" \
    && echo "GPU blobs in the image = Route A blobs (DDK 24.2@6643903)" \
    || echo "WARNING: the image's GPU blobs differ from Route A's"
fi
[ -d "$ROOT/system/apex/com.android.vndk.current" ] || "$FARM/scripts/26-check-blobs-vs-redroid.sh"

rm -rf "$C"; mkdir -p "$C/vendor"/{bin/hw,lib64,etc/init,etc/vintf/manifest,etc/seccomp_policy}
cp "$V/bin/hw/$SVC" "$C/vendor/bin/hw/"
# Only in sku=pvr containers (README 18.1), like the IMG HALs: the HAL needs Allwinner's IMG
# gralloc handles, and a declared HIDL HAL that never registers makes every getService() for
# it wait forever (MediaCodecList, hence every app that plays video). So the service is
# disabled and started with the IMG allocator (vendor.redroid.pvr=1, set by gpu_config.sh),
# and its VINTF entry goes into Route A's manifest_pvr.xml, not the always-read manifest/ folder.
sed "/^service android-hardware-media-aw-c2-hal-1-0 /a\    disabled" "$V/etc/init/$SVC.rc" > "$C/vendor/etc/init/$SVC.rc"
printf '\non property:vendor.redroid.pvr=1\n    start android-hardware-media-aw-c2-hal-1-0\n' >> "$C/vendor/etc/init/$SVC.rc"
grep -q '^    disabled' "$C/vendor/etc/init/$SVC.rc"
PVR=$FARM/out/redroid-pvr/vendor/etc/vintf/manifest_pvr.xml
[ -f "$PVR" ] || "$FARM/scripts/30-make-redroid-pvr-context.sh"
python3 -I - "$PVR" "$V/etc/vintf/manifest/manifest_media_c2_V1_0_default.xml" \
  > "$C/vendor/etc/vintf/manifest_pvr.xml" <<'PY'
import sys
import xml.etree.ElementTree as ET
base = ET.parse(sys.argv[1]).getroot()      # Route A's sku=pvr manifest, unchanged
for hal in ET.parse(sys.argv[2]).getroot().findall("hal"):
    base.append(hal)
ET.indent(base)
sys.stdout.write(ET.tostring(base, encoding="unicode") + "\n")
PY
grep -q 'android.hardware.media.c2' "$C/vendor/etc/vintf/manifest_pvr.xml"
rmdir "$C/vendor/etc/vintf/manifest"
cp "$V"/etc/media_codecs{,_allwinner_video,_google_audio,_google_video,_performance}.xml \
   "$V/etc/cedarc.conf" "$C/vendor/etc/"
cp "$V/etc/seccomp_policy/codec2.vendor.base.policy" "$C/vendor/etc/seccomp_policy/"

# Libraries: the service's DT_NEEDED closure that only the Allwinner vendor
# partition provides, plus the decoder plugins libvideoengine scans /vendor/lib64
# for and dlopen()s (the ones exporting CedarPluginVDInit). Anything redroid
# already gives a vendor process (LLNDK, VNDK, its own /vendor) is skipped; a
# system-only copy doesn't count (e.g. libcodec2_vndk: each partition has its own).
VNDK_ETC=$ROOT/system/apex/com.android.vndk.current/etc
VISIBLE=" $(cat "$VNDK_ETC"/{llndk,vndkcore,vndksp}.libraries.33.txt | tr '\n' ' ') "
have() { [[ $VISIBLE == *" $1 "* ]] || [ -e "$ROOT/vendor/lib64/$1" ]; }
declare -A SEEN=()
queue=("$V/bin/hw/$SVC")
for p in $(grep -l -a CedarPluginVDInit "$V"/lib64/libaw*.so); do queue+=("$p"); done
while [ ${#queue[@]} -gt 0 ]; do
  f=${queue[0]}; queue=("${queue[@]:1}")
  case $f in "$V"/lib64/*) cp "$f" "$C/vendor/lib64/" ;; esac
  for n in $(readelf -d "$f" | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p'); do
    [ -n "${SEEN[$n]:-}" ] && continue; SEEN[$n]=1
    [ -f "$V/lib64/$n" ] && ! have "$n" && queue+=("$V/lib64/$n")
  done
done

cat > "$C/vendor/etc/init/redroid-cedar.rc" <<'RC'
# Host device nodes are shared into the container (--privileged); open them up
# for the mediacodec user like the vendor ueventd.rc does.
on early-boot
    chmod 0666 /dev/cedar_dev
    chmod 0666 /dev/cedar_dev_ve2
    chmod 0666 /dev/deinterlace
    chmod 0666 /dev/sunxi_soc_info
    # The decoder writes AFBC-compressed frames for >= 640x480 by default; on the
    # vendor image the display engine reads them. Here SurfaceFlinger composes with
    # the PowerVR GPU, which cannot sample Arm AFBC: force linear output.
    setprop vendor.codec2.disable.afbc 1
    # The AI super-resolution path needs the NPU, which the container doesn't get.
    setprop vendor.codec2.disable.aisr 1
RC

# COPY keeps the context's modes, and Android's init skips any .rc that is group- or
# world-writable ("Skipping insecure file"): the Codec2 service would never be defined.
# Files 644, programs 755.
find "$C/vendor" -type d -exec chmod 755 {} +
find "$C/vendor" -type f -exec chmod 644 {} +
find "$C/vendor/bin" -type f -exec chmod 755 {} +
[ -z "$(find "$C/vendor" -name '*.rc' -perm /022)" ]

cat > "$C/Dockerfile" <<'DF'
# Only COPY, no RUN. Build on the board after redroid-pvr:13:
#   docker build -t redroid-pvr-c2:13 .
ARG BASE=redroid-pvr:13
FROM ${BASE}
COPY vendor/ /vendor/
DF
( cd "$C" && find . -type f | sort ) > "$C/MANIFEST.txt"
echo "context ready: $C ($(du -sh "$C" | cut -f1), $(ls "$C/vendor/lib64" | wc -l) libraries)"

# Static link check against the real redroid 13 image: the service plus the
# plugins it dlopen()s, resolved through redroid's VNDK/LLNDK and the Route A overlay.
[ -d "$FARM/out/redroid-pvr/vendor" ] || "$FARM/scripts/30-make-redroid-pvr-context.sh"
CHK=$FARM/out/cache/redroid-pvr-c2-check
rm -rf "$CHK"; mkdir -p "$CHK"
cp -r "$FARM/out/redroid-pvr/vendor/." "$CHK/"; cp -r "$C/vendor/." "$CHK/"
rm -rf "$CHK/lib64/egl" "$CHK/lib64/hw" "$CHK/bin/pvr"*   # already covered by script 26
PLUGINS=$(cd "$CHK" && grep -l -a CedarPluginVDInit lib64/libaw*.so | tr '\n' ' ')
cd / && LINK_CHECK_LIBS="$PLUGINS" python3 -E "$FARM/scripts/redroid_link_check.py" "$ROOT" "$CHK"
