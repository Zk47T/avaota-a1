#!/usr/bin/env bash
# Build the Orange Pi A733 6.6 kernel with binder on (redroid host kernel).
set -euo pipefail
source "$(dirname "$0")/env.sh"
mkdir -p "$KOUT"
# Orange Pi's own config (orangepi-build next a95129bf3, external/config/kernel/)
cp "$FARM/config/linux-sun60iw2-current-a733.config" "$KOUT/.config"
"$KSRC/scripts/kconfig/merge_config.sh" -m -O "$KOUT" "$KOUT/.config" "$FARM/config/redroid-host.fragment"
make -C "$KSRC" olddefconfig
# Show what we got for the options redroid needs
grep -E "CONFIG_(ANDROID_BINDER_IPC|ANDROID_BINDERFS|PSI|MEMFD_CREATE|OVERLAY_FS|SW_SYNC|AW_GPU_TYPE)[= ]" "$KOUT/.config"
make -C "$KSRC" -j"$JOBS" Image modules dtbs 2>&1 | tee "$FARM/out/kernel-build.log" | grep -E "error|warning: .*undefined|^  (LD|OBJCOPY).*(vmlinux|Image)$" || true
ls -la "$KOUT/arch/arm64/boot/Image"
