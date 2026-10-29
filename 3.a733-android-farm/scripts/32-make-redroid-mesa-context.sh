#!/usr/bin/env bash
# Route M: Docker build context that swaps redroid 13's Mesa 24.0.8 for our
# Mesa 26.3 PowerVR + Zink build (23-build-mesa-android.sh). Same file names
# and gralloc/composer as redroid's host-GPU mode, so only Mesa changes.
# Then a static link check against the real redroid image (as script 26).
# README section 16.13; REDROID=12 or 17 for the other Android versions (section 18).
set -euo pipefail
FARM=$(cd "$(dirname "$0")/.." && pwd)
VARIANT=${VARIANT:-base}                 # base, apercel or perf (see 23-build-mesa-android.sh)
case "$VARIANT" in base) SFX= ;; apercel|perf) SFX=-$VARIANT ;; *) echo "VARIANT: base, apercel or perf"; exit 1 ;; esac
REDROID=${REDROID:-13}                   # the redroid image underneath: 12, 13 or 17
source "$(dirname "$0")/redroid_base.sh"; redroid_base "$REDROID"
ASFX=$([ "$API" = 33 ] || echo "-api$API")
B=$FARM/out/mesa-build/android-arm64$SFX$ASFX
E=$FARM/out/toolchains/mesa-host
N=$FARM/out/toolchains/android-ndk-r29/toolchains/llvm/prebuilt/linux-x86_64/bin
C=$FARM/out/redroid-mesa$SFX$SUFFIX
[ -f "$B/src/egl/libEGL.so.1.0.0" ] || { echo "build Mesa first: API=$API VARIANT=$VARIANT ./scripts/23-build-mesa-android.sh"; exit 1; }
rm -rf "$C"; V=$C/vendor/lib64; mkdir -p "$V/egl" "$V/hw" "$V/gbm" "$C/vendor/bin" "$C/vendor/etc/init"

# File names this image's own Mesa uses: redroid 12/13 ship the Mesa 24.0.8 prebuilts with
# libdrm.so.2 (2.4.120) and libgbm.so.1; redroid 17 ships AOSP's libdrm.so and libgbm_mesa.so.
DRM2=$([ -e "$ROOT/vendor/lib64/libdrm.so.2" ] && echo 1 || true)
GBM=libgbm.so.1; [ -e "$ROOT/vendor/lib64/libgbm_mesa.so" ] && GBM=libgbm_mesa.so
# put SRC DST [SONAME]: strip, rename the SONAME to the file name redroid loads,
# and link libdrm by this image's name for it.
put() {
  install -m644 "$B/$1" "$V/$2"
  "$N/llvm-strip" --strip-unneeded "$V/$2"
  [ -z "${3:-}" ] || "$E/bin/patchelf" --set-soname "$3" "$V/$2"
  [ -z "$DRM2" ] || "$E/bin/patchelf" --replace-needed libdrm.so libdrm.so.2 "$V/$2"
}
put src/egl/libEGL.so.1.0.0                     egl/libEGL_mesa.so       libEGL_mesa.so
put src/mesa/glapi/es1api/libGLESv1_CM.so.1.1.0 egl/libGLESv1_CM_mesa.so libGLESv1_CM_mesa.so
put src/mesa/glapi/es2api/libGLESv2.so.2.0.0    egl/libGLESv2_mesa.so    libGLESv2_mesa.so
put src/gallium/targets/dri/libgallium_dri.so   libgallium_dri.so
put src/gbm/libgbm_mesa.so.1.0.0                $GBM                     $GBM
put src/gbm/backends/dri/dri_gbm.so             gbm/dri_gbm.so
put src/imagination/vulkan/libvulkan_powervr_mesa.so hw/vulkan.mesa.so   vulkan.mesa.so

# GPU selection: a powervr/apercel case in front of redroid's own script.
cat > "$C/vendor/bin/gpu_config.sh" <<'SH'
#!/system/bin/sh
# Route M: if the host's GPU driver is the open PowerVR one (DRM name "powervr"
# for Route L / mainline-based drivers, "apercel" for apercel) and mode is
# host/auto, use Mesa 26.3: PowerVR Vulkan + Zink GLES, gbm gralloc.
mode=$(getprop ro.boot.redroid_gpu_mode guest)
if [ "$mode" = "host" ] || [ "$mode" = "auto" ]; then
  [ -d /sys/kernel/debug/dri ] || mount -t debugfs none /sys/kernel/debug 2>/dev/null
  for d in /sys/kernel/debug/dri/*; do
    n=${d##*/}
    [ "$n" -ge 128 ] 2>/dev/null || continue
    drv=$(cut -d' ' -f1 "$d/name" 2>/dev/null)
    case "$drv" in
      powervr|apercel)
        echo "gpu_config: $drv on renderD$n -> Mesa PowerVR Vulkan + Zink"
        chmod 666 /dev/dri/card* /dev/dri/renderD* 2>/dev/null
        setprop gralloc.gbm.device /dev/dri/renderD$n
        setprop ro.hardware.egl mesa
        setprop ro.hardware.gralloc gbm
        setprop ro.hardware.vulkan mesa
        setprop vendor.mesa.loader.driver.override zink
        setprop ro.boot.redroid_fps 30
        exit 0
        ;;
    esac
  done
fi
exec /vendor/bin/gpu_config.orig.sh "$@"
SH
chmod 755 "$C/vendor/bin/gpu_config.sh"
# redroid's own script stays as the fallback (13: the copy in config/; 12/17: from the image)
if [ "$REDROID" = 13 ]; then install -m755 "$FARM/config/redroid-13-gpu_config.orig.sh" "$C/vendor/bin/gpu_config.orig.sh"
else install -m755 "$ROOT/vendor/bin/gpu_config.sh" "$C/vendor/bin/gpu_config.orig.sh"; fi

# redroid assumes GLES 3.2; Zink on this PowerVR reaches 3.1 (Mesa 26.3, both
# variants; 24-mesa-shim-probe.sh), so advertise 3.1. ro.* is first-set-wins,
# so patch the rc.
sed 's/setprop ro.opengles.version 196610/setprop ro.opengles.version 196609/' \
  "$ROOT/vendor/etc/init/redroid.common.rc" > "$C/vendor/etc/init/redroid.common.rc"
grep -q 'ro.opengles.version 196609' "$C/vendor/etc/init/redroid.common.rc"

# A redroid 17 built without guide fix 8 (our 20261014/20261029 images) also runs minigbm's
# gralloc 4.0, which libui prefers over gbm_gralloc (2.0), and minigbm's generic backend cannot
# allocate on a render-only GPU. Keep redroid 13's stack: minigbm's allocator off, its 4.0
# manifest entries emptied (COPY cannot delete files). Our bases from 20261029b on have no minigbm.
MG=android.hardware.graphics.allocator@4.0-service.minigbm.rc
if [ -e "$ROOT/vendor/etc/init/$MG" ]; then
  sed '/^service vendor.graphics.allocator-4-0 /a\    disabled' "$ROOT/vendor/etc/init/$MG" > "$C/vendor/etc/init/$MG"
  grep -q '^    disabled' "$C/vendor/etc/init/$MG"
  mkdir -p "$C/vendor/etc/vintf/manifest"
  for x in android.hardware.graphics.allocator@4.0.xml android.hardware.graphics.mapper@4.0.xml; do
    echo '<manifest version="1.0" type="device"/>' > "$C/vendor/etc/vintf/manifest/$x"
  done
fi

# COPY keeps the context's modes, and Android's init skips any .rc that is group- or
# world-writable ("Skipping insecure file"): a 664 redroid.common.rc means no gpu_config, no
# EGL driver, and SurfaceFlinger aborts in a loop. Files 644, programs 755.
find "$C/vendor" -type d -exec chmod 755 {} +
find "$C/vendor" -type f -exec chmod 644 {} +
find "$C/vendor/bin" -type f -exec chmod 755 {} +
[ -z "$(find "$C/vendor" -name '*.rc' -perm /022)" ]

cat > "$C/Dockerfile" <<DF
# Only COPY, no RUN: build on the board (native arm64 docker), or on a PC with
#   docker buildx build --platform linux/arm64 -t redroid-mesa:$REDROID .
# redroid's old Mesa stays in the image but is no longer loaded: the new
# libEGL_mesa.so links libgallium_dri.so directly.
ARG BASE=$BASE
FROM \${BASE}
COPY vendor/ /vendor/
DF
{ echo "Mesa $(git -C "$FARM/src/mesa$SFX" describe --tags) (+BayLibre android-17-pvr-support, +apercel DRM name; variant $VARIANT) for redroid $REDROID (API $API)"
  (cd "$C" && find vendor -type f | sort | xargs sha256sum); } > "$C/MANIFEST.txt"

# Static check against the stock image, with gralloc.gbm.so (redroid's) on our libgbm.so.1
# and dri_gbm.so as extra entry points.
K=$FARM/out/cache/redroid-mesa$SFX$SUFFIX-check; rm -rf "$K"; cp -a "$C/vendor" "$K"
cp "$ROOT/vendor/lib64/hw/gralloc.gbm.so" "$K/lib64/hw/"; cp "$K/lib64/gbm/dri_gbm.so" "$K/lib64/hw/"
cd / && python3 -E "$FARM/scripts/redroid_link_check.py" "$ROOT" "$K"
du -sh "$C"
