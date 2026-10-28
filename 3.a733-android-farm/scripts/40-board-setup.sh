#!/usr/bin/env bash
# RUN ON THE ORANGE PI (Orange Pi Debian bookworm, "current" 6.6 kernel).
# Copy the outputs to the board first, e.g.
#   rsync -a out/deploy out/redroid-pvr orangepi@<ip>:~/farm/
# Stage 1 (kernel):  ./40-board-setup.sh kernel   -> reboot
# Stage 2 (gpu+run): ./40-board-setup.sh run
set -euo pipefail
D=${FARM_DIR:-$HOME/farm}
REL=6.6.98-sun60iw2-redroid

case "${1:-}" in
kernel)
  sudo apt-get install -y "$D"/deploy/debs/linux-image-current-sun60iw2-redroid_*.deb \
                          "$D"/deploy/debs/linux-dtb-current-sun60iw2-redroid_*.deb
  echo "Installed. /boot/uImage now holds $REL (it replaces the stock uImage). Reboot, then run: $0 run"
  echo "Rollback: sudo apt install --reinstall linux-image-current-sun60iw2 && reboot"
  ;;
run)
  [ "$(uname -r)" = "$REL" ] || { echo "running $(uname -r), expected $REL (did you reboot?)"; exit 1; }
  command -v adb >/dev/null || sudo apt-get install -y adb
  echo "== 1. kernel features for redroid"
  grep -qw binder /proc/filesystems && echo "  binder (binderfs): ok" || echo "  binder: MISSING"
  [ -e /proc/pressure/memory ] && echo "  psi: ok" || echo "  psi: MISSING"

  echo "== 2. Android-flavour GPU driver (DDK 24.2@6643903) + matching firmware"
  sudo install -D -m644 "$D/deploy/lib/modules/pvrsrvkm-android.ko" /lib/modules/$REL/extra/pvrsrvkm.ko
  sudo install -D -m644 "$D/deploy/lib/firmware/rgx.fw.36.56.104.183" /lib/firmware/rgx.fw.36.56.104.183
  sudo install -D -m644 "$D/deploy/lib/firmware/rgx.sh.36.56.104.183" /lib/firmware/rgx.sh.36.56.104.183
  sudo depmod -a $REL
  echo pvrsrvkm | sudo tee /etc/modules-load.d/pvrsrvkm.conf >/dev/null
  sudo modprobe pvrsrvkm
  sleep 1; sudo dmesg | grep -i -E "pvr|rgx|sunxi bxm" | tail -15
  ls -l /dev/dri/ /dev/pvr_sync 2>/dev/null || true
  mountpoint -q /sys/kernel/debug || sudo mount -t debugfs none /sys/kernel/debug
  for n in /sys/kernel/debug/dri/*/name; do echo "  $n: $(sudo cat "$n")"; done

  echo "== 3. docker + image"
  command -v docker >/dev/null || { curl -fsSL https://get.docker.com | sudo sh; }
  if sudo docker image inspect redroid-pvr:13 >/dev/null 2>&1; then echo "image present"
  elif [ -f "$D/redroid-pvr-13-arm64.tar" ]; then sudo docker load -i "$D/redroid-pvr-13-arm64.tar"
  else (cd "$D/redroid-pvr" && sudo docker build -t redroid-pvr:13 .); fi

  echo "== 4. CPU layout: host on cpu0 (A55), Android on cpu1-7"
  # A55 = cpu0-5 (capacity 430/MHz), A76 = cpu6-7 (1024/MHz). cgroup v2 slices:
  # everything systemd starts stays on cpu0; containers go in android.slice.
  for s in system.slice user.slice init.scope; do sudo systemctl set-property --runtime $s AllowedCPUs=0; done
  sudo mkdir -p /etc/systemd/system/android.slice.d
  printf '[Slice]\nAllowedCPUs=1-7\n' | sudo tee /etc/systemd/system/android.slice.d/cpus.conf >/dev/null
  sudo systemctl daemon-reload
  # interrupts (network, eMMC, USB, GPU) on cpu0 as well
  echo 1 | sudo tee /proc/irq/default_smp_affinity >/dev/null
  for f in /proc/irq/*/smp_affinity; do echo 1 | sudo tee "$f" >/dev/null 2>&1 || true; done

  echo "== 5. memory: zram (compressed RAM swap; no swap on eMMC)"
  MEM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
  if [ "$MEM_MB" -lt 5000 ]; then ZRAM=3G; LIMIT=1600m; else ZRAM=2G; LIMIT=2200m; fi
  if ! grep -q zram0 /proc/swaps; then
    sudo modprobe zram 2>/dev/null || true
    echo zstd | sudo tee /sys/block/zram0/comp_algorithm >/dev/null
    echo $ZRAM | sudo tee /sys/block/zram0/disksize >/dev/null
    sudo mkswap /dev/zram0 >/dev/null && sudo swapon -p 100 /dev/zram0
  fi
  echo 100 | sudo tee /proc/sys/vm/swappiness >/dev/null   # zram is cheap, eMMC never used
  echo "  RAM ${MEM_MB} MB -> zram $ZRAM, container limit $LIMIT (+1G zram each)"

  echo "== 6. two instances: each 1 dedicated A76 + 2 dedicated A55 + 1 shared A55"
  # SHARED_DATA=1: apps installed once in $D/data-base, each instance keeps only its diff
  for i in 1 2; do
    if [ $i = 1 ]; then CPUS=1,2,5,6; else CPUS=3,4,5,7; fi
    if [ "${SHARED_DATA:-0}" = 1 ]; then
      VOL=(-v "$D/data-base":/data-base -v "$D/data-diff$i":/data-diff); EXTRA=androidboot.use_redroid_overlayfs=1
    else
      VOL=(-v "$D/data$i":/data); EXTRA=
    fi
    sudo docker rm -f android$i 2>/dev/null || true
    sudo docker run -itd --privileged --name android$i \
      --cgroup-parent=android.slice --cpuset-cpus=$CPUS \
      --memory=$LIMIT --memory-swap=$(( ${LIMIT%m} + 1024 ))m \
      "${VOL[@]}" -p $((5554+i)):5555 \
      redroid-pvr:13 \
      androidboot.redroid_gpu_mode=host \
      androidboot.redroid_width=720 androidboot.redroid_height=1280 androidboot.redroid_dpi=320 \
      androidboot.redroid_fps=30 androidboot.use_memfd=1 $EXTRA
  done
  echo "connect: adb connect <board-ip>:5555  and  :5556   (checks: README section 10)"
  ;;
*) echo "usage: $0 kernel|run"; exit 1;;
esac
