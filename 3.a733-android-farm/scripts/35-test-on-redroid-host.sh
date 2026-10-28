#!/usr/bin/env bash
# RUN ON A PC THAT ALREADY RUNS REDROID (not the A733 board).
# Needs: docker, adb, and out/redroid-pvr (run 00-fetch-sources.sh gpu + 30 first;
# no compiler needed for those two).
#
# arm64 host (e.g. RK3588 Orange Pi 5 Plus):
#   builds redroid-pvr:13, boots it WITHOUT a PowerVR GPU (software mode) and checks
#   1) the image still boots (proves the overlay + gated IMG allocator are safe),
#   2) every PowerVR blob links inside a real Android 13 (ldd = bionic linker),
#   3) gpu_config.sh took the fallback path.
# x86_64 host:
#   cross-builds the arm64 image (Dockerfile is COPY-only, no emulation) and saves
#   out/redroid-pvr-13-arm64.tar to carry to the A733 board (docker load -i ...).
set -euo pipefail
FARM=$(cd "$(dirname "$0")/.." && pwd)
C=$FARM/out/redroid-pvr
[ -n "${IMAGE:-}" ] || [ -f "$C/Dockerfile" ] || { echo "missing $C - run scripts/30-make-redroid-pvr-context.sh"; exit 1; }
SUDO=sudo
if [ "$(id -u)" = 0 ] || id -nG | grep -qw docker; then SUDO=; fi

case "$(uname -m)" in
aarch64|arm64)
  # IMAGE=<tag> tests an existing image (e.g. a source-built one from 31) instead
  if [ -z "${IMAGE:-}" ]; then IMAGE=redroid-pvr:13; $SUDO docker build -t $IMAGE "$C"; fi
  $SUDO docker rm -f pvrtest >/dev/null 2>&1 || true
  $SUDO docker run -itd --rm --privileged --name pvrtest -p 15555:5555 $IMAGE \
      androidboot.redroid_gpu_mode=guest
  A="adb -s 127.0.0.1:15555"
  for i in $(seq 1 60); do adb connect 127.0.0.1:15555 >/dev/null 2>&1; $A get-state >/dev/null 2>&1 && break; sleep 3; done
  echo "== waiting for boot (max 4 min)"
  for i in $(seq 1 80); do [ "$($A shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ] && break; sleep 3; done
  echo "boot_completed=$($A shell getprop sys.boot_completed | tr -d '\r')   (1 = image is safe on non-PVR hosts)"
  echo "== props"
  $A shell 'for p in ro.hardware.egl ro.hardware.vulkan ro.hardware.gralloc vendor.redroid.pvr init.svc.vendor.gralloc-4-0; do echo "$p=$(getprop $p)"; done'
  echo "== dynamic link check (bionic linker, real linkerconfig)"
  $A shell 'for f in /vendor/lib64/egl/libEGL_POWERVR_ROGUE.so /vendor/lib64/egl/libGLESv2_POWERVR_ROGUE.so \
      /vendor/lib64/hw/vulkan.powervr.so /vendor/lib64/hw/gralloc.powervr.so \
      /vendor/lib64/hw/android.hardware.graphics.mapper@4.0-impl.so \
      /vendor/bin/hw/android.hardware.graphics.allocator@4.0-service /vendor/bin/pvrsrvctl; do
      out=$(ldd $f 2>&1); if echo "$out" | grep -q -i -E "not found|cannot|error"; then echo "BAD $f"; echo "$out"; else echo "ok  $f"; fi; done'
  echo "== which mapper did SurfaceFlinger pick? (IMG 4.0 must NOT be used without PVR)"
  $A shell 'lshal 2>/dev/null | grep -i graphics.mapper; logcat -d | grep -i -E "gpu_config|mapper 4|Gralloc4|powervr|IMG" | tail -20'
  echo "keep it running for a look: adb -s 127.0.0.1:15555 shell   |  stop: $SUDO docker rm -f pvrtest"
  ;;
x86_64|amd64)
  $SUDO docker buildx build --platform linux/arm64 -t redroid-pvr:13 \
      -o type=docker,dest="$FARM/out/redroid-pvr-13-arm64.tar" "$C"
  ls -la "$FARM/out/redroid-pvr-13-arm64.tar"
  echo "copy to the board, then: sudo docker load -i redroid-pvr-13-arm64.tar"
  ;;
*) echo "unsupported host $(uname -m)"; exit 1;;
esac
