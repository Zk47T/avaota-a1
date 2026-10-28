# Source this: toolchain + paths used by all scripts.
FARM=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export FARM
# Any aarch64 GCC >= 10 works. Default: the Yocto cross GCC 13.3 already on this PC.
YOCTO_X=/home/zk47/praxis/yocto/build/tmp/sysroots-components/x86_64
if [ -z "${CROSS_COMPILE:-}" ] && [ -d "$YOCTO_X/gcc-cross-aarch64" ]; then
  # Yocto keeps gcc and binutils in separate dirs. Make a shim:
  #   shim/bu/{as,ld}      plain names gcc looks for (used only via -B)
  #   shim/bin/*-gcc       wrapper that adds -B shim/bu/ (host gcc untouched)
  SHIM=$FARM/out/yocto-shim; mkdir -p "$SHIM/bu" "$SHIM/bin"
  YG=$YOCTO_X/gcc-cross-aarch64/usr/bin/aarch64-poky-linux
  YB=$YOCTO_X/binutils-cross-aarch64/usr/bin/aarch64-poky-linux
  for t in as ld ld.bfd; do ln -sf "$YB/aarch64-poky-linux-$t" "$SHIM/bu/$t"; done
  for t in gcc cpp; do
    printf '#!/bin/sh\nexec "%s/aarch64-poky-linux-%s" -B"%s/bu/" "$@"\n' "$YG" "$t" "$SHIM" > "$SHIM/bin/aarch64-poky-linux-$t"
    chmod +x "$SHIM/bin/aarch64-poky-linux-$t"
  done
  export PATH="$SHIM/bin:$YG:$YB:$PATH"
  export CROSS_COMPILE=aarch64-poky-linux-
fi
: "${CROSS_COMPILE:=aarch64-linux-gnu-}"   # e.g. Ubuntu: apt install gcc-aarch64-linux-gnu
export CROSS_COMPILE ARCH=arm64
export KSRC=${KSRC:-$FARM/src/linux-orangepi-6.6}
# Build in-tree like orangepi-build does (some bsp/ Makefiles break with O=)
export KOUT=$KSRC
export JOBS=${JOBS:-$(nproc)}
# Own kernel name: modules go to /lib/modules/6.6.98-sun60iw2-redroid, the stock
# 6.6.98-sun60iw2 tree stays on the board for rollback.
export LOCALVERSION=${LOCALVERSION:--sun60iw2-redroid}
