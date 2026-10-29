#!/usr/bin/env bash
# Route M userspace: Mesa 26.3 (PowerVR Vulkan + Zink GLES + GBM) for redroid 13
# (Android 13, API 33, arm64). BayLibre's Android PowerVR commits rebased onto
# the upstream 26.3 branch, plus config/mesa-pvr-accept-apercel-drm-name.patch.
# README section 16.13. About 10 GB under out/ (toolchains 6 GB, builds 3 GB).
#
#   ./scripts/23-build-mesa-android.sh            everything (skips steps already done)
#   STEP=android ./scripts/23-build-mesa-android.sh   only rebuild the Android libraries
#   VARIANT=apercel ./scripts/23-build-mesa-android.sh   the same plus CheezeCS's apercel
#       Mesa 26.3 patch (Vulkan 1.3 features and limits, compiler fixes; GLES 3.1 via Zink
#       on a Zero 3W), in its own worktree src/mesa-apercel and build dirs *-apercel.
#       Needs ./scripts/00-fetch-sources.sh apercel.
#
# Needs: micromamba at out/toolchains/micromamba (or MICROMAMBA=/path), git, curl, unzip.
# Output: out/mesa-build/android-arm64 (meson build dir); 32-make-redroid-mesa-context.sh packages it.
set -euo pipefail
FARM=$(cd "$(dirname "$0")/.." && pwd)
T=$FARM/out/toolchains
B=$FARM/out/mesa-build
M0=$FARM/src/mesa
VARIANT=${VARIANT:-base}
SFX=$([ "$VARIANT" = apercel ] && echo -apercel || true)
M=$FARM/src/mesa$SFX
E=$T/mesa-host                      # conda-forge env: LLVM/clang 19, SPIRV, meson, python
TOOLS=$T/mesa-compiler$SFX          # host mesa_clc, vtn_bindgen2, pco_clc, pdsc_precomp (the
                                    # apercel patch changes the pco compiler, so its own copy)
NDK=$T/android-ndk-r29
STEP=${STEP:-all}
JOBS=${JOBS:-$(nproc)}
mkdir -p "$T" "$B"

MESA_URL=https://gitlab.freedesktop.org/mesa/mesa.git
MESA_BASE=07f74f00104644c7e3cb27b3af50e3cc96be81bd     # 26.3 branch, 2026-10-27 (26.3.0-rc2-89)
BL_URL=https://github.com/BayLibre/mesa.git
BL_TIP=92f674847202c757a07adfeb7d4bbfbf8bc1922c       # android-17-pvr-support, 2026-10-03
BL_BASE=82b868960e00805e800ee164e6696a9fa57e92b9      # its fork point on main
BL_SKIP=992647d02eabe6c309e8835bbd36f485e6161385      # riscv64-only cross-file tuning
BL_OURS=583ce30933e11ee6743b18251c92fd02b9d41307      # one-line extension-list conflict: keep 26.3's side
NDK_SHA1=87e2bb7e9be5d6a1c6cdf5ec40dd4e0c6d07c30b      # from dl.google.com repository2-3.xml
PKGS=(python=3.12.16 meson=1.12.1 ninja=1.13.2 mako=1.4.3 pyyaml=6.0.3 packaging pkg-config=0.29.2
      cmake llvmdev=19.1.7 clangdev=19.1.7 libllvmspirv=19.1.13 spirv-tools=2026.4
      bison=3.8.2 flex=2.6.4 zlib zstd expat libdrm=2.4.129 patchelf=0.19.2)

if [ "$STEP" = all ] && [ ! -x "$E/bin/llvm-config" ]; then
  MM=${MICROMAMBA:-$T/micromamba}
  [ -x "$MM" ] || { echo "need micromamba: put the linux-64 binary at $T/micromamba"; exit 1; }
  "$MM" create -y -q -r "$T/mamba" -p "$E" -c conda-forge --override-channels "${PKGS[@]}"
fi

if [ "$STEP" = all ] && [ ! -x "$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/clang" ]; then
  curl -fL --retry 3 -o "$T/ndk.zip" https://dl.google.com/android/repository/android-ndk-r29-linux.zip
  echo "$NDK_SHA1  $T/ndk.zip" | sha1sum -c
  unzip -q "$T/ndk.zip" -d "$T"; rm "$T/ndk.zip"          # unzip keeps the clang symlinks
fi

if [ "$STEP" = all ] && [ ! -d "$M0/.git" ]; then
  git clone -q --filter=blob:none -b 26.3 "$MESA_URL" "$M0"
  git -C "$M0" remote add baylibre "$BL_URL"
  git -C "$M0" fetch -q --filter=blob:none baylibre "$BL_TIP"
  git -C "$M0" switch -q -c a733-android-26.3 "$MESA_BASE"
  for c in $(git -C "$M0" rev-list --reverse "$BL_BASE..$BL_TIP"); do
    [ "$c" = "$BL_SKIP" ] && continue
    if [ "$c" = "$BL_OURS" ]; then x=(-X ours); else x=(); fi
    git -C "$M0" cherry-pick -x --allow-empty "${x[@]}" "$c" >/dev/null
  done
  git -C "$M0" apply "$FARM/config/mesa-pvr-accept-apercel-drm-name.patch"   # left uncommitted (Mesa AI policy)
fi

if [ "$STEP" = all ] && [ "$VARIANT" = apercel ] && [ ! -e "$M/.git" ]; then
  AP=$FARM/src/apercel/mesa/apercel-mesa-26.3.0-rc2.patch
  [ -f "$AP" ] || { echo "fetch it first: ./scripts/00-fetch-sources.sh apercel"; exit 1; }
  echo "$(cat "$AP.sha256")  $AP" | sha256sum -c --quiet
  git -C "$M0" worktree add -q --detach "$M" a733-android-26.3
  git -C "$M" apply --3way "$AP"      # applies to all 47 files (the new file falls back to a plain apply)
  # BayLibre already marks 36.56.104.183 conformant: drop apercel's duplicate case label.
  python3 -I - "$M/src/imagination/vulkan/pvr_physical_device.c" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
one = "   case PVR_BVNC_PACK(36, 56, 104, 183):\n      return true;\n\n"
assert s.count(one + one) == 1, "expected BayLibre's case followed by apercel's"
open(p, "w").write(s.replace(one + one, one))
PY
  # apercel renames the DRM driver to "apercel"; keep "powervr" and accept both instead.
  sed -i 's/^#define PVR_DRM_DRIVER_NAME "apercel"$/#define PVR_DRM_DRIVER_NAME "powervr"/' \
    "$M/src/imagination/vulkan/winsys/pvr_winsys.h"
  git -C "$M" apply "$FARM/config/mesa-pvr-accept-apercel-drm-name.patch"
fi

hostenv() { env -u PKG_CONFIG_PATH PATH="$TOOLS/bin:$E/bin:$PATH" LD_LIBRARY_PATH="$E/lib" "$@"; }

if [ "$STEP" = all ] && [ ! -x "$TOOLS/bin/mesa_clc" ]; then
  rm -rf "$B/native$SFX"
  (cd "$M" && hostenv PKG_CONFIG_PATH="$E/lib/pkgconfig:$E/share/pkgconfig" CC=/usr/bin/gcc CXX=/usr/bin/g++ \
    meson setup "$B/native$SFX" . -Dprefix="$TOOLS" -Dbuildtype=release -Dstrip=true \
    -Dplatforms= -Dgallium-drivers= -Dvulkan-drivers=imagination -Dimagination-srv=true \
    -Dglx=disabled -Degl=disabled -Dgbm=disabled -Dopengl=false -Dgles1=disabled -Dgles2=disabled \
    -Dllvm=enabled -Dshared-llvm=enabled -Dmesa-clc=enabled -Dinstall-mesa-clc=true \
    -Dprecomp-compiler=enabled -Dinstall-precomp-compiler=true -Dmesa-clc-bundle-headers=enabled)
  hostenv ninja -C "$B/native$SFX" -j"$JOBS" install
fi

if [ ! -f "$B/android-arm64$SFX/build.ninja" ]; then
  printf "[constants]\nndk = '%s'\nvndk = '%s'\n" "$NDK" "$M/subprojects/vndk/arm64/include" > "$B/paths$SFX.ini"
  (cd "$M" && hostenv PKG_CONFIG_LIBDIR= meson setup "$B/android-arm64$SFX" . \
    --cross-file "$B/paths$SFX.ini" --cross-file "$FARM/config/mesa-android-aarch64-api33.ini" \
    --prefix=/vendor -Dbuildtype=release \
    -Dplatforms=android -Dandroid-stub=false -Dandroid-libbacktrace=disabled -Dandroid-strict=true \
    -Dgallium-drivers=zink -Dvulkan-drivers=imagination -Dgbm=enabled -Degl=enabled \
    -Dgles1=enabled -Dgles2=enabled -Dglx=disabled -Dshared-glapi=enabled -Dplatform-sdk-version=33 \
    -Dmesa-clc=system -Dprecomp-compiler=system -Dspirv-tools=disabled -Dimagination-srv=true \
    -Dllvm=disabled -Dallow-fallback-for=libdrm,perfetto -Dgbm-backends-path=/vendor/lib64/gbm)
fi
hostenv PKG_CONFIG_LIBDIR= ninja -C "$B/android-arm64$SFX" -j"$JOBS"
echo "Mesa ($VARIANT): $(git -C "$M" describe --tags) + $(git -C "$M" rev-list --count "$MESA_BASE"..HEAD) BayLibre commits + local patch"
echo "next: VARIANT=$VARIANT ./scripts/32-make-redroid-mesa-context.sh"
