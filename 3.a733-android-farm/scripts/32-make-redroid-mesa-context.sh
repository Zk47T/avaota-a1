#!/usr/bin/env bash
# Route M: Docker build context that swaps redroid 13's Mesa 24.0.8 for our
# Mesa 26.3 PowerVR + Zink build (23-build-mesa-android.sh). Same file names
# and gralloc/composer as redroid's host-GPU mode, so only Mesa changes.
# Then a static link check against the real redroid 13 image (as script 26).
# README section 16.13.
set -euo pipefail
FARM=$(cd "$(dirname "$0")/.." && pwd)
VARIANT=${VARIANT:-base}                 # base, or apercel (see 23-build-mesa-android.sh)
case "$VARIANT" in base) SFX= ;; apercel|perf) SFX=-$VARIANT ;; *) echo "VARIANT: base, apercel or perf"; exit 1 ;; esac
B=$FARM/out/mesa-build/android-arm64$SFX
E=$FARM/out/toolchains/mesa-host
N=$FARM/out/toolchains/android-ndk-r29/toolchains/llvm/prebuilt/linux-x86_64/bin
C=$FARM/out/redroid-mesa$SFX
ROOT=$FARM/out/cache/redroid-13.0.0_64only-240527/root
[ -f "$B/src/egl/libEGL.so.1.0.0" ] || { echo "build Mesa first (23-build-mesa-android.sh)"; exit 1; }
rm -rf "$C"; V=$C/vendor/lib64; mkdir -p "$V/egl" "$V/hw" "$V/gbm" "$C/vendor/bin" "$C/vendor/etc/init"

# put SRC DST [SONAME]: strip, rename the SONAME to the file name redroid loads,
# and link libdrm by redroid's name (libdrm.so.2, 2.4.120) instead of AOSP's libdrm.so.
put() {
  install -m644 "$B/$1" "$V/$2"
  "$N/llvm-strip" --strip-unneeded "$V/$2"
  [ -z "${3:-}" ] || "$E/bin/patchelf" --set-soname "$3" "$V/$2"
  "$E/bin/patchelf" --replace-needed libdrm.so libdrm.so.2 "$V/$2"
}
put src/egl/libEGL.so.1.0.0                     egl/libEGL_mesa.so       libEGL_mesa.so
put src/mesa/glapi/es1api/libGLESv1_CM.so.1.1.0 egl/libGLESv1_CM_mesa.so libGLESv1_CM_mesa.so
put src/mesa/glapi/es2api/libGLESv2.so.2.0.0    egl/libGLESv2_mesa.so    libGLESv2_mesa.so
put src/gallium/targets/dri/libgallium_dri.so   libgallium_dri.so
put src/gbm/libgbm_mesa.so.1.0.0                libgbm.so.1              libgbm.so.1
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
install -m755 "$FARM/config/redroid-13-gpu_config.orig.sh" "$C/vendor/bin/gpu_config.orig.sh"

# redroid assumes GLES 3.2; Zink on this PowerVR reaches 3.1 (Mesa 26.3, both
# variants; 24-mesa-shim-probe.sh), so advertise 3.1. ro.* is first-set-wins,
# so patch the rc.
sed 's/setprop ro.opengles.version 196610/setprop ro.opengles.version 196609/' \
  "$ROOT/vendor/etc/init/redroid.common.rc" > "$C/vendor/etc/init/redroid.common.rc"
grep -q 'ro.opengles.version 196609' "$C/vendor/etc/init/redroid.common.rc"

cat > "$C/Dockerfile" <<'DF'
# Only COPY, no RUN: build on the board (native arm64 docker):
#   docker build -t redroid-mesa:13 .
# redroid's old Mesa (vendor/lib64/dri, libglapi.so.0) stays in the image but is
# no longer loaded: the new libEGL_mesa.so links libgallium_dri.so directly.
ARG BASE=redroid/redroid:13.0.0_64only-240527
FROM ${BASE}
COPY vendor/ /vendor/
DF
{ echo "Mesa $(git -C "$FARM/src/mesa$SFX" describe --tags) (+BayLibre android-17-pvr-support, +apercel DRM name; variant $VARIANT)"
  (cd "$C" && find vendor -type f | sort | xargs sha256sum); } > "$C/MANIFEST.txt"

# Static check against the stock image, with gralloc.gbm.so (redroid's) on our libgbm.so.1
# and dri_gbm.so as extra entry points.
K=$FARM/out/cache/redroid-mesa$SFX-check; rm -rf "$K"; cp -a "$C/vendor" "$K"
cp "$ROOT/vendor/lib64/hw/gralloc.gbm.so" "$K/lib64/hw/"; cp "$K/lib64/gbm/dri_gbm.so" "$K/lib64/hw/"
cd / && python3 -E "$FARM/scripts/redroid_link_check.py" "$ROOT" "$K"
du -sh "$C"
