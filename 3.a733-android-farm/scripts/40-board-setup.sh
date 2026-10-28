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
  echo "Installed. /boot/uImage now holds $REL. Reboot, then run: $0 run"
  echo "Rollback: sudo apt install --reinstall linux-image-current-sun60iw2 && reboot"
  ;;
run)
  [ "$(uname -r)" = "$REL" ] || { echo "running $(uname -r), expected $REL (did you reboot?)"; exit 1; }
  echo "== 1. kernel features for redroid"
  for f in binder binderfs; do grep -qw $f /proc/filesystems && echo "  $f: ok" || echo "  $f: MISSING"; done
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
  for n in /sys/kernel/debug/dri/*/name; do echo "  $n: $(sudo cat "$n")"; done

  echo "== 3. docker + image"
  command -v docker >/dev/null || { curl -fsSL https://get.docker.com | sudo sh; }
  if sudo docker image inspect redroid-pvr:13 >/dev/null 2>&1; then echo "image present"
  elif [ -f "$D/redroid-pvr-13-arm64.tar" ]; then sudo docker load -i "$D/redroid-pvr-13-arm64.tar"
  else (cd "$D/redroid-pvr" && sudo docker build -t redroid-pvr:13 .); fi

  echo "== 4. two instances, pinned (A55 = cpu0-5, A76 = cpu6-7)"
  for i in 1 2; do
    if [ $i = 1 ]; then CPUS=0,1,2,6; else CPUS=3,4,5,7; fi
    sudo docker rm -f android$i 2>/dev/null || true
    sudo docker run -itd --privileged --name android$i \
      --cpuset-cpus=$CPUS --memory=1536m --memory-swap=2g \
      -v "$D/data$i":/data -p $((5554+i)):5555 \
      redroid-pvr:13 \
      androidboot.redroid_gpu_mode=host \
      androidboot.redroid_width=720 androidboot.redroid_height=1280 androidboot.redroid_dpi=320 \
      androidboot.redroid_fps=30 androidboot.use_memfd=1
  done
  echo "connect: adb connect <board-ip>:5555  and  :5556   (checks: README section 6)"
  ;;
*) echo "usage: $0 kernel|run"; exit 1;;
esac
