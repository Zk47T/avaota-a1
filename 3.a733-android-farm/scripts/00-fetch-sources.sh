#!/usr/bin/env bash
# Recreate src/ at the exact commits this project was built and checked with.
# Shallow + sparse: ~2.5 GB download (most of it is the kernel).
#   ./scripts/00-fetch-sources.sh            all repos
#   ./scripts/00-fetch-sources.sh kernel gpu only those groups (groups: kernel gpu ref fw)
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
if want fw || [ -z "$SEL" ]; then
  # Open GPU stack references for BVNC 36.56.104.183 (same GPU as the SpacemiT K3), README 16.8:
  #  - Imagination's open-source firmware fw 1.1 build 6976702, as vendored in BayLibre's K3 AOSP tree
  #    (not in linux-firmware main yet). libgpu's copy (group "ref") is the older 1.0 build 6852738.
  #  - BayLibre's K3 / SpacemiT common device trees: the Android Mesa stack to mirror for Route M.
  FW=$FARM/src/firmware/imagination-fw-1.1
  mkdir -p "$FW"
  if ! echo "1db1c399c17401d1f79d46c880db81c724d748c784d4639433b076aba2f9c0d2  $FW/rogue_36.56.104.183_v1.fw" | sha256sum -c --status 2>/dev/null; then
    echo "fetch firmware rogue_36.56.104.183_v1.fw (1.1 build 6976702)"
    curl -fsSL -o "$FW/rogue_36.56.104.183_v1.fw" \
      "https://raw.githubusercontent.com/BayLibre/android_device_spacemit_k3/a09d86fe4703a46240cd8ae5c8a76894a761ecf0/firmware/powervr/rogue_36.56.104.183_v1.fw"
    echo "1db1c399c17401d1f79d46c880db81c724d748c784d4639433b076aba2f9c0d2  $FW/rogue_36.56.104.183_v1.fw" | sha256sum -c
  else
    echo "ok    firmware/imagination-fw-1.1"
  fi
  fetch baylibre-k3     $GH/BayLibre/android_device_spacemit_k3.git     06c4578ef02e5d19fc62ef824f2cc616a724c710
  fetch baylibre-common $GH/BayLibre/android_device_spacemit_common.git 755c243bb9f2b1dbdbe4fb7a67ba15051b50d90b
fi
du -sh "$FARM/src"
