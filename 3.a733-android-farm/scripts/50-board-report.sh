#!/usr/bin/env bash
# RUN ON THE ORANGE PI after `40-board-setup.sh run`, and again once the phones have booted.
# Prints PASS / WARN / FAIL for the checks in README section 10 and saves the evidence
# to ~/farm/reports/<time>/. Changes nothing except mounting debugfs when it is missing.
set -uo pipefail
D=${FARM_DIR:-$HOME/farm}
R="$D/reports/$(date +%Y%m%d-%H%M%S)"; mkdir -p "$R"
REL=6.6.98-sun60iw2-redroid
P=0; W=0; F=0
pass(){ echo "PASS  $*"; P=$((P+1)); }
warn(){ echo "WARN  $*"; W=$((W+1)); }
fail(){ echo "FAIL  $*"; F=$((F+1)); }
say(){ echo; echo "== $*"; }

say "1. kernel"
[ "$(uname -r)" = "$REL" ] && pass "kernel $REL" || fail "kernel is $(uname -r), expected $REL"
grep -qw binder /proc/filesystems && pass "binder filesystem" || fail "binder missing from /proc/filesystems"
[ -e /proc/pressure/memory ] && pass "PSI present" || fail "PSI missing (lmkd needs /proc/pressure)"

say "2. GPU driver and firmware (host)"
lsmod | grep -q '^pvrsrvkm' && pass "pvrsrvkm loaded" || fail "pvrsrvkm not loaded (run 40-board-setup.sh run, then check dmesg)"
sudo dmesg > "$R/dmesg.txt" 2>/dev/null
grep -iE "pvr|rgx|sunxi bxm" "$R/dmesg.txt" > "$R/dmesg-gpu.txt"
grep -qE "sunxi bxm.*end" "$R/dmesg-gpu.txt" && pass "sunxi bxm init finished" || warn "no 'sunxi bxm ... end' line in dmesg"
if grep -qiE "failed|error|timeout" "$R/dmesg-gpu.txt"; then fail "GPU errors in dmesg (see $R/dmesg-gpu.txt)"; else pass "no GPU errors in dmesg"; fi
mountpoint -q /sys/kernel/debug || sudo mount -t debugfs none /sys/kernel/debug 2>/dev/null
names=$(sudo cat /sys/kernel/debug/dri/*/name 2>/dev/null | cut -d' ' -f1 | sort -u | tr '\n' ' ')
case " $names" in *" pvr "*) pass "DRM device named 'pvr' ($names)";; *) fail "no DRM device named 'pvr' (found: ${names:-none})";; esac
ls /dev/dri/renderD* >/dev/null 2>&1 && pass "render node /dev/dri/renderD*" || fail "no /dev/dri/renderD* node"
[ -e /dev/pvr_sync ] && pass "/dev/pvr_sync" || fail "/dev/pvr_sync missing"
[ -f /lib/firmware/rgx.fw.36.56.104.183 ] && pass "GPU firmware rgx.fw.36.56.104.183 installed" || fail "GPU firmware missing in /lib/firmware"
sudo cat /sys/kernel/debug/pvr/status > "$R/pvr-status.txt" 2>/dev/null && pass "pvr/status saved" || warn "no /sys/kernel/debug/pvr/status"

say "3. docker and the image"
command -v docker >/dev/null && pass "docker installed" || fail "docker not installed"
sudo docker image inspect redroid-pvr:13 >/dev/null 2>&1 && pass "image redroid-pvr:13 present" || fail "image redroid-pvr:13 missing (docker load the tar)"
sudo docker ps -a > "$R/docker-ps.txt" 2>/dev/null

say "4. the two instances (README section 9)"
for i in 1 2; do
  port=$((5554+i))
  st=$(sudo docker inspect -f '{{.State.Status}}' "android$i" 2>/dev/null || echo missing)
  if [ "$st" != running ]; then fail "android$i is '$st' (run 40-board-setup.sh run)"; continue; fi
  pass "android$i running (adb port $port)"
  sudo docker logs "android$i" > "$R/android$i-docker.log" 2>&1
  adb connect "127.0.0.1:$port" >/dev/null 2>&1
  A="adb -s 127.0.0.1:$port"
  boot=$($A shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
  [ "$boot" = 1 ] && pass "android$i sys.boot_completed=1" || fail "android$i not booted (sys.boot_completed='${boot:-none}')"
  egl=$($A shell getprop ro.hardware.egl 2>/dev/null | tr -d '\r')
  [ "$egl" = POWERVR_ROGUE ] && pass "android$i GPU selected (ro.hardware.egl=POWERVR_ROGUE)" \
    || warn "android$i ro.hardware.egl='${egl:-none}': PowerVR not selected, software rendering"
  $A shell getprop > "$R/android$i-props.txt" 2>/dev/null
  $A shell dumpsys SurfaceFlinger > "$R/android$i-surfaceflinger.txt" 2>/dev/null
  if grep -q "PowerVR" "$R/android$i-surfaceflinger.txt"; then
    pass "android$i SurfaceFlinger reports PowerVR"
  else
    warn "android$i SurfaceFlinger does not report PowerVR (see $R/android$i-surfaceflinger.txt)"
  fi
  $A logcat -d > "$R/android$i-logcat.txt" 2>/dev/null
  n=$(grep -ciE "FATAL|tombstone|gralloc.*(error|fail)|mapper.*(error|fail)" "$R/android$i-logcat.txt")
  [ "$n" = 0 ] && pass "android$i no fatal/gralloc/mapper errors in logcat" || warn "android$i $n fatal or gralloc/mapper lines in logcat"
  echo "      memory android$i: $(sudo docker stats --no-stream --format '{{.MemUsage}}' "android$i" 2>/dev/null || echo unknown)"
done

say "5. host health"
free -m > "$R/free.txt"; df -h / > "$R/df.txt"; swapon --show > "$R/swap.txt" 2>/dev/null
echo "      RAM: $(awk '/MemAvailable/{print int($2/1024)" MB available"}' /proc/meminfo)"
echo "      SoC temperature: $(awk '{printf "%.1f C", $1/1000}' /sys/class/thermal/thermal_zone0/temp 2>/dev/null)"

say "summary"
echo "PASS $P   WARN $W   FAIL $F"
echo "evidence: $R"
[ "$F" = 0 ]
