#!/usr/bin/env bash
# Build the ANDROID flavour of the PowerVR kernel driver (pvrsrvkm.ko,
# DDK 24.2@6643903 from Radxa's public A733 Android 13 BSP) against the
# Debian host kernel from 10-build-host-kernel.sh.
# Why Android flavour: redroid containers will load the Android 13 GPU blobs
# (also 24.2@6643903). KM and UM must come from the same DDK release.
# SECURE_CONFIG=0 builds a fallback without the secure-reset patch into
# pvrsrvkm-android-nosecure.ko (README 16.12): Radxa's Linux DDK, which has no
# such writes, runs on the Zero 3W.
set -euo pipefail
source "$(dirname "$0")/env.sh"
SECURE_CONFIG=${SECURE_CONFIG:-1}
SUFFIX=$([ "$SECURE_CONFIG" = 0 ] && echo -nosecure || true)
[ -f "$KOUT/Module.symvers" ] || { echo "build the kernel first (10-build-host-kernel.sh)"; exit 1; }

SRC=$FARM/src/android-bsp/modules/gpu/img-bxm/android/rogue_km
W=$FARM/out/rogue_km-android$SUFFIX
rm -rf "$W"; cp -a "$SRC" "$W"            # never build inside src/
# The DDK only ships a profile for Arm's "aarch64-none-linux-gnu" triple;
# GCC from Yocto/Ubuntu/Debian reports "aarch64-linux-gnu". Same thing.
C=$W/build/linux/config/compilers
[ -f "$C/aarch64-linux-gnu.mk" ] || cp "$C/aarch64-none-linux-gnu.mk" "$C/aarch64-linux-gnu.mk"
# Allwinner hard-coded "$(KERNELDIR)/source/Makefile" (only exists in GKI-style
# O= builds); with a plain in-tree kernel grep then reads stdin and hangs.
# Put back Imagination's original fallback, which is left commented out in the file.
sed -i 's|^ override KERNEL_MAKEFILE := $(KERNELDIR)/source/Makefile$| override KERNEL_MAKEFILE := $(shell realpath $(KERNELDIR)/source/Makefile 2>/dev/null \|\| echo $(KERNELDIR)/Makefile)|' \
  "$W/build/linux/config/kernel_version.mk"
# Android flavour forces clang ("override KERNEL_CC := clang") because AOSP
# dropped GCC. Our host kernel is GCC-built, so modules must be GCC too.
sed -i 's|^override KERNEL_CC := clang$|KERNEL_CC ?= clang|' "$W/build/linux/common/android/features.mk"
# Platform glue: port the GPU secure-reset release that Orange Pi's working
# Linux driver does before every GPU start (see the patch header).
[ "$SECURE_CONFIG" = 0 ] || patch -d "$W" -p1 --forward < "$FARM/config/pvrsrvkm-android-sunxi-secure-config.patch"

# Read the GPU DVFS switch from the kernel config, like Allwinner's wrapper does
if grep -q '^CONFIG_DEVFREQ_GOV_SIMPLE_ONDEMAND=y' "$KOUT/.config"; then DVFS=1; else DVFS=0; fi

make -C "$W/build/linux/sunxi_android" -j"$JOBS" \
  BUILD=release \
  KERNELDIR="$KOUT" \
  CROSS_COMPILE="$CROSS_COMPILE" KERNEL_CROSS_COMPILE="$CROSS_COMPILE" \
  KERNEL_CC="${CROSS_COMPILE}gcc" KERNEL_LD="${CROSS_COMPILE}ld" \
  KERNEL_NM="${CROSS_COMPILE}gcc-nm" KERNEL_OBJCOPY="${CROSS_COMPILE}objcopy" \
  HOST_CC=gcc HOST_CXX=g++ \
  TARGET_ARCH=arm64 TARGET_DEVICE=sun60iw2 PLATFORM_RELEASE=13.0 \
  CONFIG_DEVFREQ_GOV_SIMPLE_ONDEMAND=$DVFS \
  kbuild 2>&1 | tee "$FARM/out/pvrsrvkm-android$SUFFIX.log" | grep -E "error|Error|warning: |pvrsrvkm\.ko" || true

KO=$(find "$W" -name pvrsrvkm.ko | head -1)
[ -n "$KO" ] || { echo "FAILED, see out/pvrsrvkm-android$SUFFIX.log"; exit 1; }
mkdir -p "$FARM/out/deploy/lib/modules" "$FARM/out/deploy/lib/firmware"
cp "$KO" "$FARM/out/deploy/lib/modules/pvrsrvkm-android$SUFFIX.ko"
"${CROSS_COMPILE}strip" --strip-debug "$FARM/out/deploy/lib/modules/pvrsrvkm-android$SUFFIX.ko"
# Firmware must match this KM build too (Android copy, not the Debian one)
cp "$FARM/src/android-gpu/img-rgx/bxm/etc/firmware/"rgx.{fw,sh}.36.56.104.183 "$FARM/out/deploy/lib/firmware/"
modinfo "$FARM/out/deploy/lib/modules/pvrsrvkm-android$SUFFIX.ko" | grep -E "vermagic|^name|firmware|alias: of" || true
echo "DDK in KM : $(strings "$KO" | grep -m1 -E 'rogueddk|24\.2@')"
echo "DDK in UM : $(strings "$FARM/src/android-gpu/img-rgx/bxm/arm64/lib64/egl/libGLESv2_POWERVR_ROGUE.so" | grep -m1 'build 24')"
