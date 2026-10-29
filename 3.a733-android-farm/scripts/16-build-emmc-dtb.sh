#!/usr/bin/env bash
# Device trees for a hand-fitted eMMC (README 8.4). The Orange Pi trees enable
# the eMMC controller (sdc2) but leave both supplies commented out, which works
# only while the rails happen to be on. This turns them on for sdc2 only:
#   vmmc  = reg_dc1sw2 (3.3 V, VCC_3V3_EMMC)   vqmmc = reg_cldo1 (1.8 V, VCC-1V8-EMMC)
# Same change as config/zero3w-emmc-supplies.patch. Meter-check VCCQ = 1.8 V first.
#   ./scripts/16-build-emmc-dtb.sh            zero3w and zero4
#   ./scripts/16-build-emmc-dtb.sh zero4
set -euo pipefail
source "$(dirname "$0")/env.sh"
DTS=$KSRC/arch/arm64/boot/dts/allwinner
OUT=$FARM/out/emmc-dtb
mkdir -p "$OUT"
[ -x "$KSRC/scripts/dtc/dtc" ] || make -C "$KSRC" ARCH=arm64 scripts_dtc >/dev/null

build() {   # build SRC.dts DST.dtb; -@ keeps __symbols__ for U-Boot overlays, as the kernel's dtbs build does
  cpp -nostdinc -I "$DTS" -I "$KSRC/scripts/dtc/include-prefixes" -I "$KSRC/bsp/include" -undef -D__DTS__ \
      -x assembler-with-cpp "$1" | "$KSRC/scripts/dtc/dtc" -q -@ -I dts -O dtb -o "$2" -
}
for b in ${*:-zero3w zero4}; do
  src=$DTS/sun60i-a733-orangepi-$b.dts
  tmp=$DTS/.emmc-$b.dts
  awk '/^&sdc2 \{/ {in2=1}
       in2 && /\/\*vmmc-supply = <&reg_cldo3>;\*\// {sub(/\/\*vmmc-supply = <&reg_cldo3>;\*\//, "vmmc-supply = <\\&reg_dc1sw2>;"); n++}
       in2 && /\/\*vqmmc-supply = <&reg_cldo1>;\*\// {sub(/\/\*vqmmc-supply = <&reg_cldo1>;\*\//, "vqmmc-supply = <\\&reg_cldo1>;"); n++}
       in2 && /^\};/ {in2=0}
       {print}
       END {if (n != 2) {print "expected 2 supply lines in &sdc2, changed " n > "/dev/stderr"; exit 1}}' "$src" > "$tmp"
  build "$src" "$OUT/stock-$b.dtb"
  build "$tmp" "$OUT/sun60i-a733-orangepi-$b-emmc.dtb"
  rm -f "$tmp"
  # the only difference must be the two supplies of the eMMC controller
  diff <("$KSRC/scripts/dtc/dtc" -q -I dtb -O dts "$OUT/stock-$b.dtb") \
       <("$KSRC/scripts/dtc/dtc" -q -I dtb -O dts "$OUT/sun60i-a733-orangepi-$b-emmc.dtb") \
       | grep '^[<>]' | sed "s/^/  $b: /" || true
  rm -f "$OUT/stock-$b.dtb"
done
( cd "$OUT" && sha256sum *-emmc.dtb > SHA256SUMS )
ls -l "$OUT"
