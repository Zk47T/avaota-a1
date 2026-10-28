#!/usr/bin/env bash
# Fetch the A733 DRAM material analysed in ../README.md into src/ (git-ignored:
# vendor binaries). ~60 MB.
set -euo pipefail
T=$(cd "$(dirname "$0")/.." && pwd)/src; mkdir -p "$T"; cd "$T"
GL=https://gitlab.com
clone() { # dir url branch [sparse paths...]
  local d=$1 u=$2 b=$3; shift 3
  [ -d "$d/.git" ] && { echo "ok    $d"; return; }
  echo "fetch $d"
  if [ $# -gt 0 ]; then
    git clone -q --depth 1 --filter=blob:none --sparse -b "$b" "$u" "$d"
    git -C "$d" sparse-checkout set --no-cone "$@"
  else git clone -q --depth 1 -b "$b" "$u" "$d"; fi
}
# Allwinner libdram (boot0 DRAM driver) + ARISC standby firmware lib, A733 = sun60iw2p1
clone dramlib-tina    $GL/tina5.0_aiot/lichee/dramlib.git  product-aiot-stable   # V0.6035, 2026-07
clone dramlib-android $GL/aw_android13/lichee/dramlib.git  a733-radxa-v1.0       # V0.601,  2025-07
# Orange Pi boot0 (Zero 3W variants) + scp.fex (ARISC firmware) as shipped
clone orangepi-build  https://github.com/orangepi-xunlong/orangepi-build.git next '/external/packages/pack-uboot/sun60iw2/'
# SyterKit: A733 OpenOCD config, DRAM glue, FEL DRAM-init app
mkdir -p syterkit; R=https://raw.githubusercontent.com/YuzukiHD/SyterKit/HEAD
for f in scripts/openocd/allwinner_a733.cfg drivers/dram/dram-sun60iw2.c soc/sun60iw2/app_efex/init_dram/main.c include/drivers/dram/dram.h; do
  mkdir -p "syterkit/$(dirname $f)"; curl -sf -o "syterkit/$f" "$R/$f"; done
# NXP i.MX95 LPDDR5 (same Synopsys PHY) for comparison: open OEI timing file
mkdir -p nxp; curl -sf -o nxp/mx95lp5_frdm_timing.c \
  "https://raw.githubusercontent.com/nxp-imx/imx-oei/HEAD/boards/mx95lp5-15-frdm/ddr/MIMX95_LPDDR5_FRDM_15X15_4266MTS_FW2024.09_timing.c"
du -sh "$T"
