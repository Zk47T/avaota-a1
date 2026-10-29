#!/usr/bin/env bash
# RUN ON THE ORANGE PI after `40-board-setup.sh kernel` and the reboot, before step 5
# (BOARD-DAY 4a-4c). Loads one open GPU driver with insmod, never depmod, so a power
# cycle undoes it. Saves the evidence to ~/farm/gpu-tests/<time>-<test>/ and syncs
# after every step, so a hang still leaves the log on the card.
#   ./41-gpu-open-tests.sh apercel       apercel + Imagination fw 1.1         (step 4a)
#   ./41-gpu-open-tests.sh routel        Orange Pi powervr.ko + libgpu fw 1.0  (step 4b)
#   ./41-gpu-open-tests.sh routel-fw11   powervr.ko + fw 1.1                   (step 4c)
#   ./41-gpu-open-tests.sh unload        rmmod apercel / powervr (never pvrsrvkm)
# With /opt/mesa-farm installed (out/host-mesa, script 27), each test also runs vulkaninfo,
# the GL/GLES version probe and the GLES 3.1 smoke test on the GPU. DRYRUN=1 prints the
# root commands instead of running them.
set -uo pipefail
D=${FARM_DIR:-$HOME/farm}
REL=6.6.98-sun60iw2-redroid
FW=rogue_36.56.104.183_v1.fw
FW10=3974e79f77e0228f6a76d9523bc77a638e679f05e0e97afcb1aa27e7f870c072
FW11=1db1c399c17401d1f79d46c880db81c724d748c784d4639433b076aba2f9c0d2
MESA=/opt/mesa-farm
T=${1:-}
root() { if [ -n "${DRYRUN:-}" ]; then echo "[dry] $*" >&2; else sudo "$@"; fi; }
# grep without -q in pipes: with pipefail, an early grep exit can fail the writer (SIGPIPE)
loaded() { lsmod | grep "^$1 " >/dev/null; }

case "$T" in
  apercel)     MD=$D/apercel;  MOD=apercel; ARGS=no_autosuspend=1; FWDIR=apercel; FWSRC=$D/fw/1.1; FWSUM=$FW11; VER="v1.1 (build 6976702 OS)" ;;
  routel)      MD=$D/route-l;  MOD=powervr; ARGS=;                 FWDIR=powervr; FWSRC=$D/fw/1.0; FWSUM=$FW10; VER="v1.0 (build 6852738 OS)" ;;
  routel-fw11) MD=$D/route-l;  MOD=powervr; ARGS=;                 FWDIR=powervr; FWSRC=$D/fw/1.1; FWSUM=$FW11; VER="v1.1 (build 6976702 OS)" ;;
  unload)
    for m in apercel powervr; do loaded $m && root rmmod $m && echo "unloaded $m"; done
    echo "The helpers (gpu_sched, drm_exec, drm_shmem_helper) stay loaded; they are harmless. Reboot before step 5."
    exit 0 ;;
  *) sed -n '2,12p' "$0"; exit 2 ;;
esac

# Guard rails (BOARD-DAY 4a, README 16.12): our kernel, no pvrsrvkm on the GPU,
# one open driver at a time.
if [ -z "${DRYRUN:-}" ]; then
  [ "$(uname -r)" = "$REL" ] || { echo "running $(uname -r), expected $REL"; exit 1; }
  loaded pvrsrvkm && { echo "pvrsrvkm is loaded: reboot without it (never rmmod it on a live GPU)"; exit 1; }
  for m in apercel powervr; do
    [ "$m" = "$MOD" ] && [ "$T" != routel-fw11 ] && loaded $m && { echo "$m is already loaded: $0 unload first"; exit 1; }
    [ "$m" != "$MOD" ] && loaded $m && { echo "$m is loaded: $0 unload first"; exit 1; }
  done
fi
(cd "$MD" && sha256sum -c --quiet SHA256SUMS) || { echo "module files in $MD don't match SHA256SUMS"; exit 1; }
echo "$FWSUM  $FWSRC/$FW" | sha256sum -c --quiet || { echo "wrong firmware in $FWSRC"; exit 1; }

O=$D/gpu-tests/$(date +%Y%m%d-%H%M%S)-$T; mkdir -p "$O"
log() { echo "$*" | tee -a "$O/summary.txt"; sync; }
keep() { local f=$1; shift; "$@" > "$O/$f" 2>&1; sync; }   # keep a command's output

# PCK-600 status registers, PD 5 (GPU_TOP) and PD 6 (GPU_CORE); 0x8 = on (README 16.7)
devmem() {
  if command -v busybox >/dev/null && busybox --list | grep -x devmem >/dev/null; then root busybox devmem "$1"
  elif command -v devmem2 >/dev/null; then root devmem2 "$1" w | awk '/Value at address/ {print $NF}'
  else echo "n/a (sudo apt install busybox)"; fi
}
pd() { log "$1: PD5 GPU_TOP $(devmem 0x07065008)  PD6 GPU_CORE $(devmem 0x07066008)"; }

log "== $T on $(uname -r), $(date -Is)"
log "modules from $MD, firmware $FWSRC/$FW -> /lib/firmware/$FWDIR/"
pd "before"
N0=$(root dmesg | wc -l)

root install -D -m 0644 "$FWSRC/$FW" "/lib/firmware/$FWDIR/$FW"
[ "$T" = routel-fw11 ] && loaded powervr && root rmmod powervr
for m in gpu-sched drm_exec drm_shmem_helper; do
  loaded "${m//-/_}" || root insmod "$MD/$m.ko" || log "FAIL insmod $m"
done
sync
if root insmod "$MD/$MOD.ko" $ARGS; then log "insmod $MOD${ARGS:+ $ARGS}: ok"; else log "FAIL insmod $MOD (see dmesg)"; fi
sleep 5

keep dmesg-test.txt sh -c "$( [ -n "${DRYRUN:-}" ] && echo 'echo [dry] dmesg' || echo "sudo dmesg | tail -n +$((N0 + 1))" )"
keep dmesg-full.txt root dmesg
mountpoint -q /sys/kernel/debug || root mount -t debugfs none /sys/kernel/debug
NAMES=$(root sh -c 'cat /sys/kernel/debug/dri/*/name 2>/dev/null' | cut -d' ' -f1 | sort -u | tr '\n' ' ')
keep dri.txt sh -c 'ls -l /dev/dri; grep -i gpu /proc/interrupts; cat /sys/class/devfreq/*gpu*/cur_freq 2>/dev/null'
pd "after"

grep -q "FW version $VER" "$O/dmesg-test.txt" && log "PASS firmware $VER" || log "FAIL no 'FW version $VER' line"
case " $NAMES" in *" $MOD "*) log "PASS DRM device '$MOD'";; *) log "FAIL no DRM device '$MOD' (found: ${NAMES:-none})";; esac
NODE=   # the render node whose device is bound to the driver under test, not just any GPU
for n in /sys/class/drm/renderD*; do
  [ "$(basename "$(readlink -f "$n/device/driver" 2>/dev/null)")" = "$MOD" ] && NODE=/dev/dri/${n##*/}
done
[ -n "$NODE" ] && log "PASS render node $NODE ($MOD)" || log "FAIL no render node bound to $MOD"
grep -i -E "$MOD|powervr|rogue|firmware|deferring|unsupported|incorrect gpu" "$O/dmesg-test.txt" | tail -20 | tee -a "$O/summary.txt"

# Real GPU work, only with a render node and the host Mesa. A hang here is a result:
# everything above is already on the card. Root, because the login user may not be
# in the render group; mesa-farm-run sets the Mesa paths itself, so sudo's reset env is fine.
if [ -n "$NODE" ] && [ -x "$MESA/bin/mesa-farm-run" ]; then
  R=$MESA/bin/mesa-farm-run
  if command -v vulkaninfo >/dev/null; then
    keep vulkaninfo.txt root timeout 60 "$R" vulkaninfo --summary
    log "vulkaninfo: $(grep -m1 -E 'deviceName' "$O/vulkaninfo.txt" | sed 's/^ *//') $(grep -m1 apiVersion "$O/vulkaninfo.txt" | sed 's/^ *//')"
  else log "vulkaninfo missing: sudo apt install libvulkan1 vulkan-tools"; fi
  keep glver.txt root timeout 60 "$R" "$MESA/bin/mesa_glver"
  log "GL/GLES: $(grep -E ': OK' "$O/glver.txt" | head -2 | tr '\n' ' ')"
  keep glsmoke.txt root timeout 300 "$R" "$MESA/bin/mesa_glsmoke"
  log "smoke: $(tail -1 "$O/glsmoke.txt")"
else
  log "skipped the rendering checks (no render node, or $MESA not installed: out/host-mesa)"
fi
log "== evidence in $O"
[ "$T" = routel-fw11 ] && log "fw 1.1 is now in /lib/firmware/powervr/. To put 1.0 back: sudo install -D -m 0644 $D/fw/1.0/$FW /lib/firmware/powervr/$FW"
log "next: $0 unload, then the next test, or reboot before BOARD-DAY step 5"
