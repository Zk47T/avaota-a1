#!/usr/bin/env bash
# Recreate src/ at the exact commits this project was built and checked with.
# Shallow + sparse: ~2.5 GB download (most of it is the kernel).
#   ./scripts/00-fetch-sources.sh            all repos
#   ./scripts/00-fetch-sources.sh kernel gpu only those groups (groups: kernel gpu ref fw apercel opi storage;
#                                            opi = Orange Pi docs + Android images, storage = eMMC/UFS datasheets; both only when named)
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
  # Allwinner's Codec2 HAL source for A733 Android 13 (README 17.4)
  fetch aw-libcodec2 $GL/aw_android13/platform/tidy/platform/hardware/aw/libcodec2.git 7ac742728423d885631602cea0ef7e8eb145f2ec
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
if want apercel || [ -z "$SEL" ]; then
  # Open host GPU driver proven on the Orange Pi Zero 3W (README 16.10), built by 22-build-apercel.sh:
  #  - CheezeCS fork = TumRedSun/apercel e098b9f + 30 backported upstream drm/imagination fixes + Mesa 26.3 patch
  #  - CheezeCS/armbian-a733-gpu: the Armbian integration (Kconfig prompts, Mesa build script, docs)
  fetch apercel         $GH/CheezeCS/apercel.git          d03675d4a38e1aa8eb7c0e982e213893a8631baa
  fetch armbian-a733-gpu $GH/CheezeCS/armbian-a733-gpu.git 6960be5081795368f697a8da772f76d71a5203ff
fi
# drive FILE ID SHA256: one file from Orange Pi's public Google Drive, checked
drive() {
  if echo "$3  $1" | sha256sum -c --status 2>/dev/null; then echo "ok    ${1##*/}"; return; fi
  echo "fetch ${1##*/}"
  mkdir -p "$(dirname "$1")"
  curl -fsSL -o "$1" "https://drive.usercontent.google.com/download?id=$2&export=download&confirm=t"
  echo "$3  $1" | sha256sum -c
}
# dl FILE URL SHA256: one public file, checked
dl() {
  if echo "$3  $1" | sha256sum -c --status 2>/dev/null; then echo "ok    ${1##*/}"; return; fi
  echo "fetch ${1##*/}"
  mkdir -p "$(dirname "$1")"
  curl -fsSL -A 'Mozilla/5.0' -o "$1" "$2"
  echo "$3  $1" | sha256sum -c
}
if want storage; then   # eMMC/UFS datasheets for the Zero 3W / Zero 4 footprints (README 3.13)
  DS=$FARM/../2.docs/storage-datasheets
  dl "$DS/Samsung_eMMC5.1_KLMxGxJETD_Rev1.1.pdf" \
     https://e2e.ti.com/cfs-file/__key/communityserver-discussions-components-files/791/Samsung-eMMC_2D00_2611204514.pdf \
     c7298e2876faf32827e1754c4a3e53830821886863a7d23484949fe3d8b11326
  dl "$DS/Samsung_KLMBG2JETD_readthedocs.pdf" \
     https://smc-storage-chips-datasheets.readthedocs.io/en/latest/emmc/klmbg2jetd-datasheet.pdf \
     ed9812c09617aaca23bff0bc51da4330562c2945e76522edaaa7986160e9fa60
  dl "$DS/Kingston_UFS3.1_UFS64G-UFS128-TX17_v1.1_lcsc.pdf" \
     https://atta.szlcsc.com/upload/public/pdf/source/20240130/0FB2C071753AAB32143AD137C1FB1602.pdf \
     6276f3c914fe02d3e4e52729d0edc2f2037c233c6909cf977305feb84a8c95c7
fi
if want opi; then   # not in the default set: 3.3 GB of images
  # Orange Pi's official A733 documents (README 17.1) and Android images (README 17.2).
  # The images feed scripts/33 (Codec2 HAL) and the DDK 25.1 notes. Checked 2026-10-29.
  DOC=$FARM/../2.docs/orangepi-a733
  drive "$DOC/OrangePi_Zero3W_A733_User Manual_v1.0.pdf"  1R1MC9erKTztd87GvJ_UFE132x6KgPATe a4593068bf885296ea204529b880e874acb8f060bb21735c833f63305adb8cdf
  drive "$DOC/OPI ZERO 3W V1_2 Schematic Diagram.pdf"     1layhtSvMpQo-z_iMJjNfNVvhPhObpsvW 4e0e92afbb1cca97a9c8593b8f2679178d9738f242ea431ed3650e893fe28ed0
  drive "$DOC/OrangePi_Zero4_A733_User Manual_v1.0.pdf"   18DO5XfrXanwJIxG3GP1tOxrkdexNzRO4 3045e84c96baacb2b29b40159128640a613a41343b87254dee9266910a345b6c
  drive "$DOC/Opi zero 4 V1_5.zip"                        11n_jS-nm30nq894ldpM5Aca4b7AIzcGa 76e6b0bf150acfe202ebafcbef065b7679621ca8422dcb992d161480ee63b518
  drive "$DOC/OrangePi_4_Pro_A733_User Manual_v1.4.pdf"   1ztP6FUIX1H1b1q_i6v-wVLBoDi6-RfWE 91197f6046cb59a7032ee5fc45f08cafa9986e213bff7a8abf2d8be2492f23ce
  drive "$DOC/OPI 4 PRO V1_3_2_20260109.pdf"              1uBjcmxtbsLXRwO0SNQnwHng_JTqoSl7X 94870b7c131a551821ed15c3450a221dcab8999099a140b18941048af67cda08
  IMG=$FARM/out/cache/opi-android
  drive "$IMG/OrangePiZero3W_A733_Android13_v1.0.tar.gz"  1pkdnQSufB3uY3vTj3uskWLsNV8w7cPD1 8081ff479cb1e621a09ada104cb0b865325b559dae76e0a2f5f46ceffe606c4d
  drive "$IMG/OrangePiZero4_A733_Android16_v1.0.tar.gz"   1utu_-tKOYXmWC0F5LHazwTJ2Jw8OWUAY f5a491e2faae8eff73dbac400662e4d30dacdef4255ed89b6bbeaa3b68b4b40c
  # the board-day host OS (BOARD-DAY step 1; README 8.4 measured its size)
  drive "$FARM/out/cache/opi-debian/Orangepizero3w_1.0.2_debian_trixie_server_linux6.6.98.7z" \
        1hPlHFaNq5PtgR3gq1yOcm7Xqo0Y2Cy7V 5473e154c199f75733662c6f7a05c8d518ba3f57d905037e8d34037c6109055f
fi
du -sh "$FARM/src"
