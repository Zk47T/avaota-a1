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
# IMG allocator service: make it "disabled" and start it only when gpu_config.sh
# found the PowerVR driver. Otherwise it crash-loops on a non-PVR host and its
# "onrestart restart surfaceflinger" keeps the container from ever booting.
sed '/^service vendor.gralloc-4-0 /a\    disabled' \
  "$B/etc/init/android.hardware.graphics.allocator@4.0-service.img.rc" \
  > "$C/vendor/etc/init/android.hardware.graphics.allocator@4.0-service.img.rc"
cat > "$C/vendor/etc/init/redroid-pvr.rc" <<'RC'
# set by /vendor/bin/gpu_config.sh when the host exposes the "pvr" DRM device
on property:vendor.redroid.pvr=1
    start vendor.gralloc-4-0
RC
if [ -e "$ROOT/vendor/etc/vintf/manifest/android.hardware.graphics.allocator@4.0.xml" ]; then
  # redroid 17 declares minigbm's gralloc 4.0 under these names. The IMG HALs take them
  # over (one IAllocator 4.0 instance), and minigbm's allocator service is switched off.
  cp "$B/etc/vintf/manifest/android.hardware.graphics.allocator@4.0.img.xml" \
     "$C/vendor/etc/vintf/manifest/android.hardware.graphics.allocator@4.0.xml"
  cp "$B/etc/vintf/manifest/android.hardware.graphics.mapper@4.0-passthrough.img.xml" \
     "$C/vendor/etc/vintf/manifest/android.hardware.graphics.mapper@4.0.xml"
  MG=android.hardware.graphics.allocator@4.0-service.minigbm.rc
  sed '/^service vendor.graphics.allocator-4-0 /a\    disabled' "$ROOT/vendor/etc/init/$MG" > "$C/vendor/etc/init/$MG"
  grep -q '^    disabled' "$C/vendor/etc/init/$MG"
else
  cp "$B"/etc/vintf/manifest/*.xml "$C/vendor/etc/vintf/manifest/"
fi
cp "$B/etc/powervr.ini" "$C/vendor/etc/"
# Note: firmware is loaded by the HOST kernel (request_firmware -> host /lib/firmware),
# not from the container. 40-board-setup.sh installs it on the host.

# --- GPU selection: add a "pvr" case in front of redroid's own script ---
cat > "$C/gpu_config.sh" <<'SH'
#!/system/bin/sh
# redroid gpu_config.sh wrapper: if the host exposes the PowerVR DRM node
# ("pvr", from pvrsrvkm) and mode is host/auto, use the IMG blobs.
# Otherwise fall back to the stock redroid logic (mesa / swiftshader).
mode=$(getprop ro.boot.redroid_gpu_mode guest)
pvr=""
if [ "$mode" = "host" ] || [ "$mode" = "auto" ]; then
  # debugfs is not mounted inside a container by default: mount it if we can
  [ -d /sys/kernel/debug/dri ] || mount -t debugfs none /sys/kernel/debug 2>/dev/null
  for n in /sys/kernel/debug/dri/*/name; do
    [ -f "$n" ] || continue
    [ "$(cut -d' ' -f1 "$n")" = "pvr" ] && pvr=1
  done
  # no debugfs view: accept the loaded module with its render and sync nodes
  if [ -z "$pvr" ] && [ -d /sys/module/pvrsrvkm ] && [ -e /dev/pvr_sync ] \
     && ls /dev/dri/renderD* >/dev/null 2>&1; then
    pvr=1
    echo "gpu_config: pvrsrvkm loaded (no debugfs name); using module + render node"
  fi
fi
if [ -n "$pvr" ]; then
  echo "gpu_config: PowerVR (pvrsrvkm) found -> IMG blobs"
  chmod 666 /dev/dri/card* /dev/dri/renderD* 2>/dev/null
  [ -e /dev/pvr_sync ] && chmod 666 /dev/pvr_sync
  setprop ro.hardware.egl POWERVR_ROGUE
  setprop ro.hardware.vulkan powervr
  setprop ro.hardware.gralloc powervr
  setprop ro.boot.redroid_fps 30
  setprop vendor.redroid.pvr 1     # starts IMG allocator (redroid-pvr.rc)
  exit 0
fi
echo "gpu_config: no PowerVR DRM node -> stock redroid path (IMG allocator stays off)"
exec /vendor/bin/gpu_config.orig.sh "$@"
SH
chmod +x "$C/gpu_config.sh"

# redroid's own script is kept as the fallback (13: the copy in config/, taken from
# redroid:13.0.0_64only-240527; 12/17: from the image itself)
if [ "$REDROID" = 13 ]; then install -m755 "$FARM/config/redroid-13-gpu_config.orig.sh" "$C/vendor/bin/gpu_config.orig.sh"
else install -m755 "$ROOT/vendor/bin/gpu_config.sh" "$C/vendor/bin/gpu_config.orig.sh"; fi
install -m755 "$C/gpu_config.sh" "$C/vendor/bin/gpu_config.sh"; rm "$C/gpu_config.sh"

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
