#!/usr/bin/env bash
# Recreate src/ at the exact commits this project was built and checked with.
# Shallow + sparse: ~2.5 GB download (most of it is the kernel).
#   ./scripts/00-fetch-sources.sh            all repos
#   ./scripts/00-fetch-sources.sh kernel gpu only those groups
set -euo pipefail
FARM=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$FARM/src"

# fetch DIR URL COMMIT [sparse paths...]   (no paths = full checkout)
fetch() {
  local dir=$1 url=$2 sha=$3; shift 3
  local d="$FARM/src/$dir"
  if [ -d "$d/.git" ] && [ "$(git -C "$d" rev-parse HEAD 2>/dev/null)" = "$sha" ]; then
    echo "ok    $dir @ ${sha:0:9}"; return
  fi
  echo "fetch $dir @ ${sha:0:9}"
  rm -rf "$d"; git init -q "$d"
  git -C "$d" remote add origin "$url"
  if [ $# -gt 0 ]; then
    git -C "$d" config extensions.partialClone origin
    git -C "$d" sparse-checkout set --no-cone "$@"
    git -C "$d" fetch -q --depth 1 --filter=blob:none origin "$sha"
  else
    git -C "$d" fetch -q --depth 1 origin "$sha"
  fi
  git -C "$d" checkout -q FETCH_HEAD
}

want() { [[ " $SEL " == *" $1 "* ]]; }
SEL="${*:-}"

GL=https://gitlab.com; GH=https://github.com
if want kernel || [ -z "$SEL" ]; then
  # Orange Pi A733 6.6 kernel (bsp/ merged in-tree) - the redroid host kernel
  fetch linux-orangepi-6.6 $GH/orangepi-xunlong/linux-orangepi.git 2ac08e8c7cdc28abbdc5c9a9dd812f887ae9c79f
fi
if want gpu || [ -z "$SEL" ]; then
  # Radxa/Allwinner A733 Android 13 SDK: GPU kernel driver source + userspace blobs (24.2@6643903)
  fetch android-bsp $GL/aw_android13/lichee/bsp.git 1775e037b5bb20df56b44cd6b5237506ac90fb34 '/modules/gpu/img-bxm/'
  fetch android-gpu $GL/aw_android13/gpu/gpu.git    c923a387981881035e96920d2ea7b27f5b38ee10 '/img-rgx/bxm/' '/include/' '/config/' '/Android.mk'
fi
if want ref || [ -z "$SEL" ]; then
  # Reference only (not needed by the build scripts)
  fetch bsp         $GL/tina5.0_aiot/lichee/bsp.git                     a5fe197076f2fed46223ac911588b4e6e6bffd3c '/modules/gpu/' '/drivers/gpu/imagination/'
  fetch libgpu      $GL/tina5.0_aiot/product/linux/external/libgpu.git  144487e873671ba9817005f08c2abd4756dd4241 '/img-bxm/' '/gpu-firmware/'
  fetch device-a733 $GL/tina5.0_aiot/lichee/device/config/a733.git      fe97b52284c56fd1c3c347f526bee00b07fc830d
  fetch radxa-android-manifest $GH/radxa/allwinner-android-manifests  ed4ee7b1718569b0fe14932345b51776b9b42331
  fetch device_redroid-13 $GH/remote-android/device_redroid           736f66d8548e75c1255f8fe97b8e90c21e7dda35
  fetch orangepi-build-cfg $GH/orangepi-xunlong/orangepi-build.git    a95129bf30ea11886cc35f08ebb3e69695a26656 \
        '/external/config/boards/orangepizero3w.conf' '/external/config/boards/orangepizero4.conf' \
        '/external/config/kernel/*sun60iw2*' '/external/config/sources/families/sun60iw2.conf' \
        '/external/config/bootscripts/boot-sun60iw2.cmd' '/external/packages/bsp/sun60iw2/' \
        '/external/packages/pack-uboot/sun60iw2/'
fi
du -sh "$FARM/src"
