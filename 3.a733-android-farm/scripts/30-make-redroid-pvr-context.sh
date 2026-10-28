#!/usr/bin/env bash
# Assemble a Docker build context that layers the A733 PowerVR Android 13
# blobs (DDK 24.2@6643903) on top of the stock redroid 13 arm64 image.
# The image itself is built ON THE BOARD (native arm64 docker), see README.
set -euo pipefail
source "$(dirname "$0")/env.sh"
B=$FARM/src/android-gpu/img-rgx/bxm
C=$FARM/out/redroid-pvr
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
cp "$B"/etc/vintf/manifest/*.xml "$C/vendor/etc/vintf/manifest/"
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

# redroid's own script (taken from redroid:13.0.0_64only-240527) is kept as the fallback
install -m755 "$FARM/config/redroid-13-gpu_config.orig.sh" "$C/vendor/bin/gpu_config.orig.sh"
install -m755 "$C/gpu_config.sh" "$C/vendor/bin/gpu_config.sh"; rm "$C/gpu_config.sh"

cat > "$C/Dockerfile" <<'DF'
# Only COPY, no RUN: builds on the board, or on a PC with
#   docker buildx build --platform linux/arm64 -t redroid-pvr:13 .
ARG BASE=redroid/redroid:13.0.0_64only-240527
FROM ${BASE}
COPY vendor/ /vendor/
DF
( cd "$C" && find . -type f | sort ) > "$C/MANIFEST.txt"
echo "context ready: $C ($(du -sh "$C" | cut -f1))"
