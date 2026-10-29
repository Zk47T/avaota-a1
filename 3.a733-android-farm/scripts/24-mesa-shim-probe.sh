#!/usr/bin/env bash
# Probe our Route M Mesa without a board: build it for x86 with Mesa's PowerVR
# no-op drm-shim, pretend to be BVNC 36.56.104.183, and record what the
# Vulkan driver exposes and which GL/GLES versions Zink reaches on top of it.
# Feature/limit/version queries are real driver code; nothing is executed on a GPU.
# README section 16.14. Needs the toolchain and source from 23-build-mesa-android.sh.
#
#   ./scripts/24-mesa-shim-probe.sh               base variant
#   VARIANT=apercel ./scripts/24-mesa-shim-probe.sh     (or perf)
#   ASSERTS=1 ./scripts/24-mesa-shim-probe.sh     a separate build with Mesa's asserts on, for the
#                                                 smoke test (mesa_glsmoke.c) to catch driver bugs
set -euo pipefail
FARM=$(cd "$(dirname "$0")/.." && pwd)
T=$FARM/out/toolchains
E=$T/mesa-host
VARIANT=${VARIANT:-base}
case "$VARIANT" in base) SFX= ;; apercel|perf) SFX=-$VARIANT ;; *) echo "VARIANT: base, apercel or perf"; exit 1 ;; esac
M=$FARM/src/mesa$SFX
TOOLS=$T/mesa-compiler$SFX
ASSERTS=${ASSERTS:-0}
X=$FARM/out/mesa-build/x86-shim$SFX$([ "$ASSERTS" = 1 ] && echo -asserts || true)
L=$T/libdrm-sys
R=$FARM/out/mesa-shim-results
JOBS=${JOBS:-$(nproc)}
mkdir -p "$R"
[ -x "$TOOLS/bin/mesa_clc" ] || { echo "run 23-build-mesa-android.sh (VARIANT=$VARIANT) first"; exit 1; }

# The shim hooks stat()/readdir(); conda's libdrm is built against old glibc
# headers and calls __xstat, which the shim does not hook on glibc >= 2.33.
# A libdrm built with the system compiler calls stat64 and is seen by the shim.
if [ ! -f "$L/lib/libdrm.so.2" ]; then
  rm -rf "$T/libdrm-src"
  git clone -q --depth 1 -b libdrm-2.4.129 https://gitlab.freedesktop.org/mesa/drm.git "$T/libdrm-src"
  (cd "$T/libdrm-src" && env PATH="$E/bin:$PATH" CC=/usr/bin/gcc meson setup build -Dprefix="$L" -Dlibdir=lib \
     -Dintel=disabled -Dradeon=disabled -Damdgpu=disabled -Dnouveau=disabled -Dvmwgfx=disabled \
     -Dfreedreno=disabled -Detnaviv=disabled -Dvc4=disabled -Dexynos=disabled -Domap=disabled \
     -Dtegra=disabled -Dcairo-tests=disabled -Dvalgrind=disabled -Dman-pages=disabled -Dtests=false \
   && env PATH="$E/bin:$PATH" ninja -C build install)
fi
# Vulkan loader + vulkaninfo for the probe (no-op if already there)
[ -x "$E/bin/vulkaninfo" ] || "${MICROMAMBA:-$T/micromamba}" install -y -q -r "$T/mamba" -p "$E" \
  -c conda-forge --override-channels libvulkan-loader vulkan-tools

if [ ! -f "$X/build.ninja" ]; then
  (cd "$M" && env -u PKG_CONFIG_PATH PATH="$TOOLS/bin:$E/bin:$PATH" LD_LIBRARY_PATH="$E/lib" \
     PKG_CONFIG_PATH="$L/lib/pkgconfig:$E/lib/pkgconfig:$E/share/pkgconfig" CC=/usr/bin/gcc CXX=/usr/bin/g++ \
     meson setup "$X" . -Dbuildtype=debugoptimized -Db_ndebug=$([ "$ASSERTS" = 1 ] && echo false || echo true) \
     -Dplatforms= -Degl=enabled -Dgles1=disabled -Dgles2=enabled -Dopengl=true -Dglx=disabled -Dgbm=enabled \
     -Dgallium-drivers=zink -Dvulkan-drivers=imagination -Dimagination-srv=false -Dtools=drm-shim \
     -Dmesa-clc=system -Dprecomp-compiler=system -Dllvm=disabled -Dvalgrind=disabled -Dlibunwind=disabled)
fi
env PATH="$TOOLS/bin:$E/bin:$PATH" LD_LIBRARY_PATH="$E/lib" ninja -C "$X" -j"$JOBS"
for t in mesa_glver mesa_glsmoke; do
  gcc -o "$X/$t" "$FARM/scripts/$t.c" -I"$M/include" \
    -L"$X/src/egl" -L"$X/src/mesa/glapi/es2api" -lEGL -lGLESv2 \
    -Wl,-rpath,"$X/src/egl:$X/src/mesa/glapi/es2api"
done

run() {
  env LD_LIBRARY_PATH="$L/lib:$X/src/gallium/targets/dri:$E/lib" \
      LD_PRELOAD="$X/src/imagination/drm-shim/libpowervr_noop_drm_shim.so" \
      PVR_SHIM_DEVICE_BVNC=36.56.104.183 \
      VK_ICD_FILENAMES="$X/src/imagination/vulkan/powervr_mesa_devenv_icd.x86_64.json" \
      VK_LOADER_LAYERS_DISABLE='*' "$@" 2>&1 | grep -v 'Loader Message\|DISPLAY'
}
TAG=$VARIANT$([ "$ASSERTS" = 1 ] && echo -asserts || true)
run "$X/mesa_glsmoke" > "$R/glsmoke-$TAG.txt" || true
tail -3 "$R/glsmoke-$TAG.txt"
[ "$ASSERTS" = 1 ] && exit 0
run "$E/bin/vulkaninfo" > "$R/vulkaninfo-$VARIANT.txt"
run "$X/mesa_glver" > "$R/glver-$VARIANT.txt"
EXTS=1 run "$X/mesa_glver" | grep '^EXT' | tr ' ' '\n' | grep '^GL_' | sort > "$R/gles31-extensions-$VARIANT.txt"
grep -m3 -E 'apiVersion|deviceName|driverInfo' "$R/vulkaninfo-$VARIANT.txt"
grep -E ': (OK|no context)' "$R/glver-$VARIANT.txt"
grep -m2 GL_VERSION "$R/glver-$VARIANT.txt"
echo "$(wc -l < "$R/gles31-extensions-$VARIANT.txt") GLES 3.1 extensions -> $R/"
