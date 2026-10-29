#!/usr/bin/env bash
# Host Mesa for the board (Debian trixie arm64): PowerVR Vulkan + Zink, so the
# open GPU drivers can be checked with real rendering as soon as they load
# (BOARD-DAY 4a/4b). Cross-built in a Debian trixie container (the board's own
# library versions), then checked under qemu with Mesa's PowerVR drm-shim.
# README section 16.18.
#
#   ./scripts/27-build-host-mesa.sh     our Route M tree (src/mesa, 23-build-mesa-android.sh): it binds
#       to DRM name "powervr" (Route L) and "apercel", headless EGL (surfaceless) + GBM + Vulkan
#       -> out/host-mesa/mesa-farm-arm64.tar.gz, unpacks to /opt/mesa-farm
#   VARIANT=cheezecs ./scripts/27-build-host-mesa.sh     CheezeCS's a733-build-mesa: Mesa 26.3.0-rc2
#       + apercel patch (DRM name "apercel" only, X11 + Wayland), the build proven on a Zero 3W
#       -> out/host-mesa/a733-mesa_*_arm64.deb, installs to /opt/mesa-apercel
#
# Needs docker; qemu-user binfmt for the check (skipped without it). The default variant also
# needs 23-build-mesa-android.sh done (tree and host tools); cheezecs needs fetch group apercel.
set -euo pipefail
FARM=$(cd "$(dirname "$0")/.." && pwd)
VARIANT=${VARIANT:-farm}
O=$FARM/out/host-mesa
mkdir -p "$O"

if [ "$VARIANT" = cheezecs ]; then
  S=$FARM/src/armbian-a733-gpu/files/mesa/a733-build-mesa
  [ -f "$S" ] && [ -d "$FARM/src/apercel/mesa" ] || { echo "fetch it first: ./scripts/00-fetch-sources.sh apercel"; exit 1; }
  # The script wants root on amd64 Debian trixie: give it a throwaway container.
  # Name the platform: the arm64 check below re-points the local debian:trixie tag.
  docker run --rm --platform linux/amd64 -v "$FARM/src/apercel:/usr/src/apercel:ro" -v "$S:/usr/local/bin/a733-build-mesa:ro" \
    -v "$O:/out" debian:trixie bash -c \
    "a733-build-mesa --cross --deb /out --prefix /opt/mesa-apercel --jobs $(nproc) && chown -R $(id -u):$(id -g) /out"
  D=$(ls -t "$O"/a733-mesa_*_arm64.deb | head -1)
  dpkg-deb -f "$D" Package Version Depends
  # apercel's Mesa finds the GPU by DRM name "apercel" (BOARD-DAY failure table). grep without -q:
  # with pipefail, an early exit would kill dpkg-deb with SIGPIPE and fail the check.
  dpkg-deb --fsys-tarfile "$D" | tar -xO --wildcards '*/libvulkan_powervr_mesa.so' | strings | grep -x apercel >/dev/null \
    && echo "DRM name apercel: present"
  (cd "$O" && sha256sum a733-mesa_*_arm64.deb > SHA256SUMS.cheezecs)
  exit 0
fi
[ "$VARIANT" = farm ] || { echo "VARIANT: farm (default) or cheezecs"; exit 1; }

M=$FARM/src/mesa
T=$FARM/out/toolchains
B=$FARM/out/mesa-build/linux-arm64
P=/opt/mesa-farm
L=$P/lib/aarch64-linux-gnu
STAGE=$FARM/out/mesa-build/linux-arm64-stage
[ -x "$T/mesa-compiler/bin/mesa_clc" ] || { echo "run 23-build-mesa-android.sh first"; exit 1; }

# Build container: cross GCC and the board's arm64 dev libraries from trixie.
docker image inspect a733-mesa-cross:trixie >/dev/null 2>&1 || docker build --platform linux/amd64 -q -t a733-mesa-cross:trixie - <<'DF'
FROM debian:trixie
RUN dpkg --add-architecture arm64 && apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      crossbuild-essential-arm64 binutils meson ninja-build pkgconf bison flex git ca-certificates \
      python3 python3-mako python3-yaml python3-packaging \
      libdrm-dev:arm64 libexpat1-dev:arm64 zlib1g-dev:arm64 libzstd-dev:arm64 \
 && rm -rf /var/lib/apt/lists/*
DF

# Reuse the host tools from the Route M build (same tree, so the same precompiled
# shaders). They need the conda env's LLVM: wrap them instead of exporting
# LD_LIBRARY_PATH, which would leak into the container's compiler and python.
W=$FARM/out/mesa-build/linux-arm64-tools; rm -rf "$W"; mkdir -p "$W"
for t in mesa_clc vtn_bindgen2 pco_clc pdsc_precomp; do
  printf '#!/bin/sh\nLD_LIBRARY_PATH=%s exec %s "$@"\n' "$T/mesa-host/lib" "$T/mesa-compiler/bin/$t" > "$W/$t"
  chmod +x "$W/$t"
done
cat > "$W/cross-arm64.ini" <<'INI'
[binaries]
c = 'aarch64-linux-gnu-gcc'
cpp = 'aarch64-linux-gnu-g++'
ar = 'aarch64-linux-gnu-ar'
nm = 'aarch64-linux-gnu-nm'
strip = 'aarch64-linux-gnu-strip'
pkg-config = 'pkg-config'

[properties]
pkg_config_libdir = ['/usr/lib/aarch64-linux-gnu/pkgconfig', '/usr/share/pkgconfig']

[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
INI

# Same paths inside the container: the conda env and the wrappers use absolute paths.
run() { docker run --rm --platform linux/amd64 --user "$(id -u):$(id -g)" -e HOME=/tmp -e PATH="$W:/usr/local/bin:/usr/bin:/bin" \
          -v "$FARM:$FARM" -w "$M" a733-mesa-cross:trixie "$@"; }
[ -f "$B/build.ninja" ] || { rm -rf "$B"; run meson setup "$B" . --cross-file "$W/cross-arm64.ini" \
  --prefix="$P" --libdir=lib/aarch64-linux-gnu -Dbuildtype=release \
  -Dplatforms= -Degl=enabled -Dgbm=enabled -Dopengl=true -Dgles1=disabled -Dgles2=enabled -Dglx=disabled \
  -Dgallium-drivers=zink -Dvulkan-drivers=imagination -Dimagination-srv=false \
  -Dmesa-clc=system -Dprecomp-compiler=system -Dllvm=disabled -Dvalgrind=disabled -Dlibunwind=disabled \
  -Dtools=drm-shim -Dbuild-tests=false; }
run ninja -C "$B" -j"$(nproc)"
rm -rf "$STAGE"
run env DESTDIR="$STAGE" meson install -C "$B" --strip --no-rebuild --quiet
mkdir -p "$STAGE$P/bin"   # Mesa itself installs no programs with these options

# The test programs from 24-mesa-shim-probe.sh, plus a runner in the style of
# CheezeCS's tools/mesa-run: the system Mesa (/usr) stays untouched.
for t in mesa_glver mesa_glsmoke; do
  # -rpath is where the board finds the libraries; -rpath-link lets ld follow libEGL's own
  # dependencies (libgallium, libgbm) in the staging copy at link time
  run aarch64-linux-gnu-gcc -O2 -o "$STAGE$P/bin/$t" "$FARM/scripts/$t.c" -I"$M/include" \
    -L"$STAGE$L" -lEGL -lGLESv2 -Wl,-rpath,"$L" -Wl,-rpath-link,"$STAGE$L"
done
cat > "$STAGE$P/bin/mesa-farm-run" <<SH
#!/bin/sh
# Run one command against $P (PowerVR Vulkan + Zink); the system Mesa stays as it is.
#   $P/bin/mesa-farm-run vulkaninfo --summary
#   $P/bin/mesa-farm-run $P/bin/mesa_glsmoke
export LD_LIBRARY_PATH="$L\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
export LIBGL_DRIVERS_PATH="$L/dri" GBM_BACKENDS_PATH="$L/gbm"
export VK_DRIVER_FILES="$P/share/vulkan/icd.d/powervr_mesa_icd.aarch64.json"
export VK_ICD_FILENAMES="\$VK_DRIVER_FILES"
export MESA_LOADER_DRIVER_OVERRIDE="\${MESA_LOADER_DRIVER_OVERRIDE:-zink}"
exec "\$@"
SH
chmod 755 "$STAGE$P/bin/mesa-farm-run"
V="Mesa $(git -C "$M" describe --tags) (Route M tree: 26.3 + BayLibre android-17-pvr-support + accept-both DRM-name patch)"
mkdir -p "$STAGE$P/share/doc/mesa-farm"
printf '%s\nBuilt by scripts/27-build-host-mesa.sh for Debian trixie arm64.\nNeeds: libvulkan1 (and vulkan-tools for vulkaninfo).\n' "$V" \
  > "$STAGE$P/share/doc/mesa-farm/VERSION"
tar -C "$STAGE" --owner=0 --group=0 -czf "$O/mesa-farm-arm64.tar.gz" opt
(cd "$O" && sha256sum mesa-farm-arm64.tar.gz > SHA256SUMS.farm)
echo "$V"; ls -l "$O/mesa-farm-arm64.tar.gz"

# Check under qemu: an arm64 trixie container with only the runtime packages, our
# tarball, and the no-op drm-shim pretending to be BVNC 36.56.104.183. The queries
# are real driver code; nothing runs on a GPU.
if [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then echo "no qemu-aarch64 binfmt: check skipped"; exit 0; fi
R=$FARM/out/mesa-shim-results; mkdir -p "$R"
docker run --rm --platform linux/arm64 -v "$FARM:$FARM:ro" debian:trixie bash -c "
  apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
    libvulkan1 vulkan-tools libdrm2 libexpat1 zlib1g libzstd1 >/dev/null
  tar -C / -xzf $O/mesa-farm-arm64.tar.gz
  export LD_PRELOAD=$B/src/imagination/drm-shim/libpowervr_noop_drm_shim.so PVR_SHIM_DEVICE_BVNC=36.56.104.183
  echo '== vulkaninfo'; $P/bin/mesa-farm-run vulkaninfo --summary 2>&1 | grep -E 'apiVersion|deviceName|driverInfo' | head -3
  echo '== GL/GLES versions'; $P/bin/mesa-farm-run $P/bin/mesa_glver 2>&1 | grep -E ': (OK|no context)'
  echo '== smoke'; $P/bin/mesa-farm-run $P/bin/mesa_glsmoke 2>&1 | tail -2
" 2>&1 | grep -v 'Loader Message\|DISPLAY' | tee "$R/host-mesa-arm64-qemu.txt"
