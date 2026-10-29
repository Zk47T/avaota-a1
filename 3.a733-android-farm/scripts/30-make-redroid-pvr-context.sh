#!/usr/bin/env bash
# Assemble a Docker build context that layers the A733 PowerVR Android 13
# blobs (DDK 24.2@6643903) on top of the stock redroid 13 arm64 image.
# REDROID=12 or 17 puts the same blobs on redroid 12 or our redroid 17 (README 18);
# those two are also link-checked here (13 is checked by script 26).
# The image itself is built ON THE BOARD (native arm64 docker), see README.
set -euo pipefail
source "$(dirname "$0")/env.sh"
REDROID=${REDROID:-13}
source "$(dirname "$0")/redroid_base.sh"; redroid_base "$REDROID"
B=$FARM/src/android-gpu/img-rgx/bxm
C=$FARM/out/redroid-pvr$SUFFIX
rm -rf "$C"; mkdir -p "$C/vendor"/{lib64/egl,lib64/hw,bin/hw,etc/init,etc/vintf/manifest}

# --- userspace driver (64-bit only; redroid 64only image) ---
cp "$B"/arm64/lib64/egl/lib{EGL,GLESv1_CM,GLESv2}_POWERVR_ROGUE.so  "$C/vendor/lib64/egl/"
for l in libIMGegl libsrv_um libglslcompiler libusc libufwriter libpvrANDROID_WSEGL \
         libPVRScopeServices libgpudataproducer libPVROCL; do
  cp "$B/arm64/lib64/$l.so" "$C/vendor/lib64/"
done
cp "$B/arm64/lib64/hw/vulkan.POWERVR_ROGUE.so"  "$C/vendor/lib64/hw/vulkan.powervr.so"
cp "$B/arm64/lib64/hw/gralloc.powervr.so"       "$C/vendor/lib64/hw/gralloc.powervr.so"
cp "$B/arm64/lib64/hw/android.hardware.graphics.mapper@4.0-impl.so" "$C/vendor/lib64/hw/"
cp "$B/arm64/bin/hw/android.hardware.graphics.allocator@4.0-service" "$C/vendor/bin/hw/"
cp "$B/arm64/bin/pvrsrvctl" "$B/arm64/bin/pvrdebug" "$C/vendor/bin/"
# redroid 17 (no VNDK, no ION) lacks libion.so, which gralloc.powervr.so links. Borrow
# Android 13's (needs only liblog/libc++): the DDK allocates through libdmabufheap, and
# ion_open is a leftover path (our kernel has DMA-BUF heaps, no ION).
if [ ! -e "$ROOT/vendor/lib64/libion.so" ] && [ ! -e "$ROOT/system/apex/com.android.vndk.current/lib64/libion.so" ]; then
  ION=$FARM/out/cache/redroid-13.0.0_64only-240527/root/system/apex/com.android.vndk.current/lib64/libion.so
  [ -f "$ION" ] || { echo "run ./scripts/26-check-blobs-vs-redroid.sh first (it caches redroid 13)"; exit 1; }
  cp "$ION" "$C/vendor/lib64/"
fi
# IMG allocator service: make it "disabled" and start it only in sku=pvr containers
# (gpu_config.sh below). On a non-PVR host it crash-loops, and its
# "onrestart restart surfaceflinger" keeps the container from ever booting.
sed '/^service vendor.gralloc-4-0 /a\    disabled' \
  "$B/etc/init/android.hardware.graphics.allocator@4.0-service.img.rc" \
  > "$C/vendor/etc/init/android.hardware.graphics.allocator@4.0-service.img.rc"
cat > "$C/vendor/etc/init/redroid-pvr.rc" <<'RC'
# set by /vendor/bin/gpu_config.sh when the host exposes the "pvr" DRM device
on property:vendor.redroid.pvr=1
    start vendor.gralloc-4-0
RC
# Declare the IMG gralloc HALs only for containers started with androidboot.product.vendor.sku=pvr
# (40-board-setup.sh sets it when pvrsrvkm is up): libvintf then reads manifest_pvr.xml instead of
# manifest.xml. A HAL that is declared but never started hangs boot: libui's IAllocator::getService()
# waits forever for any hwbinder HAL the manifest declares (libhidl ServiceManagement.cpp).
python3 -I - "$ROOT/vendor/etc/vintf/manifest.xml" "$B"/etc/vintf/manifest/*.xml \
  > "$C/vendor/etc/vintf/manifest_pvr.xml" <<'PY'
import sys
import xml.etree.ElementTree as ET
base = ET.parse(sys.argv[1]).getroot()     # the image's own manifest, attributes kept
for frag in sys.argv[2:]:
    for hal in ET.parse(frag).getroot().findall("hal"):
        # The DDK's allocator entry names its instance twice (<version>+<interface> and <fqname>).
        # Android 12/13 accept that; Android 17's libvintf rejects the whole manifest
        # ("Duplicated ..."), and with no manifest keystore2 crashes and init gives up.
        named = {f"@{v.text.strip()}::{i.findtext('name').strip()}/{n.text.strip()}"
                 for v in hal.findall("version") for i in hal.findall("interface")
                 for n in i.findall("instance")}
        for fq in hal.findall("fqname"):
            if fq.text.strip() in named:
                hal.remove(fq)
        base.append(hal)
ET.indent(base)
sys.stdout.write(ET.tostring(base, encoding="unicode") + "\n")
PY
grep -q 'android.hardware.graphics.allocator' "$C/vendor/etc/vintf/manifest_pvr.xml"
MG=android.hardware.graphics.allocator@4.0-service.minigbm.rc
if [ -e "$ROOT/vendor/etc/init/$MG" ]; then
  # A redroid 17 built without guide fix 8 also declares minigbm's gralloc 4.0 (our 20261029b
  # and later bases do not). With the IMG HALs it would be a second IAllocator 4.0, and without them
  # minigbm cannot allocate on this GPU: off in both cases, its manifest entries emptied
  # (COPY cannot delete files), so the stock path is gbm_gralloc 2.0.
  sed '/^service vendor.graphics.allocator-4-0 /a\    disabled' "$ROOT/vendor/etc/init/$MG" > "$C/vendor/etc/init/$MG"
  grep -q '^    disabled' "$C/vendor/etc/init/$MG"
  for x in android.hardware.graphics.allocator@4.0.xml android.hardware.graphics.mapper@4.0.xml; do
    echo '<manifest version="1.0" type="device"/>' > "$C/vendor/etc/vintf/manifest/$x"
  done
fi
cp "$B/etc/powervr.ini" "$C/vendor/etc/"
# Note: firmware is loaded by the HOST kernel (request_firmware -> host /lib/firmware),
# not from the container. 40-board-setup.sh installs it on the host.

# --- GPU selection: add a "pvr" case in front of redroid's own script ---
cat > "$C/gpu_config.sh" <<'SH'
#!/system/bin/sh
# redroid gpu_config.sh wrapper. The host decides: a container started with
# androidboot.product.vendor.sku=pvr declares the IMG gralloc HALs (manifest_pvr.xml), so it
# must use the IMG blobs and start their allocator, or SurfaceFlinger waits for it forever.
# Without that flag nothing IMG is declared, and the stock redroid logic runs (mesa / swiftshader).
if [ "$(getprop ro.boot.product.vendor.sku)" = pvr ]; then
  # a sanity line only: the host checked pvrsrvkm before passing the flag
  [ -d /sys/module/pvrsrvkm ] && [ -e /dev/pvr_sync ] \
    || echo "gpu_config: WARNING sku=pvr but no pvrsrvkm/pvr_sync in the container"
  echo "gpu_config: sku=pvr -> IMG blobs"
  chmod 666 /dev/dri/card* /dev/dri/renderD* 2>/dev/null
  [ -e /dev/pvr_sync ] && chmod 666 /dev/pvr_sync
  setprop ro.hardware.egl POWERVR_ROGUE
  setprop ro.hardware.vulkan powervr
  setprop ro.hardware.gralloc powervr
  setprop ro.boot.redroid_fps 30
  setprop vendor.redroid.pvr 1     # starts IMG allocator (redroid-pvr.rc)
  exit 0
fi
echo "gpu_config: no sku=pvr -> stock redroid path (IMG HALs not declared, allocator off)"
exec /vendor/bin/gpu_config.orig.sh "$@"
SH
chmod +x "$C/gpu_config.sh"

# redroid's own script is kept as the fallback (13: the copy in config/, taken from
# redroid:13.0.0_64only-240527; 12/17: from the image itself)
if [ "$REDROID" = 13 ]; then install -m755 "$FARM/config/redroid-13-gpu_config.orig.sh" "$C/vendor/bin/gpu_config.orig.sh"
else install -m755 "$ROOT/vendor/bin/gpu_config.sh" "$C/vendor/bin/gpu_config.orig.sh"; fi
install -m755 "$C/gpu_config.sh" "$C/vendor/bin/gpu_config.sh"; rm "$C/gpu_config.sh"

# COPY keeps the context's modes, and Android's init skips any .rc that is group- or
# world-writable ("Skipping insecure file"): with this PC's umask 002 the IMG allocator would
# never be defined. Files 644, programs 755.
find "$C/vendor" -type d -exec chmod 755 {} +
find "$C/vendor" -type f -exec chmod 644 {} +
find "$C/vendor/bin" -type f -exec chmod 755 {} +
[ -z "$(find "$C/vendor" -name '*.rc' -perm /022)" ]

cat > "$C/Dockerfile" <<DF
# Only COPY, no RUN: builds on the board, or on a PC with
#   docker buildx build --platform linux/arm64 -t redroid-pvr:$REDROID .
ARG BASE=$BASE
FROM \${BASE}
COPY vendor/ /vendor/
DF
( cd "$C" && find . -type f | sort ) > "$C/MANIFEST.txt"
echo "context ready: $C ($(du -sh "$C" | cut -f1))"
[ "$REDROID" = 13 ] || { cd / && python3 -E "$FARM/scripts/redroid_link_check.py" "$ROOT" "$C/vendor"; }
