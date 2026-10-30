#!/usr/bin/env bash
# RUN ON THE ORANGE PI (Orange Pi Debian trixie 1.0.2, 6.6.98 kernel).
# Copy the outputs to the board first, e.g.
#   rsync -a out/deploy out/redroid-pvr out/redroid-pvr-c2 orangepi@<ip>:~/farm/
# Stage 1 (kernel):  ./40-board-setup.sh kernel   -> reboot
# Stage 2 (gpu+run): ./40-board-setup.sh run
#   CODEC2=1 ./40-board-setup.sh run   also gives the containers the video engine
#                                      (Allwinner Codec2 HAL, script 33, README 17)
#   IMAGE1=redroid-pvr:12 IMAGE2=redroid-pvr:17 ./40-board-setup.sh run
#                                      other Android versions per instance (README 18)
set -euo pipefail
D=${FARM_DIR:-$HOME/farm}
REL=6.6.98-sun60iw2-redroid

case "${1:-}" in
kernel)
  sudo apt-get install -y "$D"/deploy/debs/linux-image-current-sun60iw2-redroid_*.deb \
                          "$D"/deploy/debs/linux-dtb-current-sun60iw2-redroid_*.deb
  echo "Installed. /boot/uImage now holds $REL (it replaces the stock uImage). Reboot, then run: $0 run"
  echo "Rollback: sudo tar -C / -xpf ~/stock-kernel-backup.tar && sudo reboot (BOARD-DAY step 2; apt has no Orange Pi kernel)"
  ;;
run)
  [ "$(uname -r)" = "$REL" ] || { echo "running $(uname -r), expected $REL (did you reboot?)"; exit 1; }
  command -v adb >/dev/null || sudo apt-get install -y adb
  echo "== 1. kernel features for redroid"
  grep -qw binder /proc/filesystems && echo "  binder (binderfs): ok" || echo "  binder: MISSING"
  [ -e /proc/pressure/memory ] && echo "  psi: ok" || echo "  psi: MISSING"

  echo "== 1b. netfilter modules for Android's netd and for docker (README 18.2)"
  # Every container's init empties the board's kernel.modprobe, so from then on the kernel cannot
  # load a module on demand, for anyone. Load what netd's iptables rules need (the legacy tables,
  # bpf, mark, TCPMSS and REJECT are built in) and what docker's nftables port mappings need, now
  # and at every boot. xt_quota2 exists only in Android kernels; without it netd's data-usage
  # alerts fail, as on any mainline kernel.
  NF="xt_owner xt_u32 xt_connmark xt_state xt_conntrack xt_NFLOG nfnetlink_log xt_IDLETIMER xt_CT
      xt_policy xt_limit xt_quota xt_MASQUERADE xt_nat iptable_nat ip6table_nat xt_pkttype
      xt_length xt_helper xt_statistic xt_socket
      nf_tables nft_compat nft_chain_nat nft_nat nft_ct nft_masq nft_reject_ipv4 nft_reject_ipv6 xt_addrtype"
  for m in $NF; do sudo modprobe "$m" 2>/dev/null || echo "  $m: could not load"; done
  printf '%s\n' $NF | sudo tee /etc/modules-load.d/redroid-netd.conf >/dev/null

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
  if [ "${CODEC2:-0}" = 1 ]; then
    echo "== 2b. video engine for the containers' Codec2 HAL"
    sudo modprobe sunxi-ve && sudo modprobe deinterlace || true
    printf 'sunxi-ve\ndeinterlace\n' | sudo tee /etc/modules-load.d/sunxi-ve.conf >/dev/null
    ls -l /dev/cedar_dev* /dev/deinterlace /dev/sunxi_soc_info 2>/dev/null || true
  fi

  echo "== 3. docker + image"
  command -v docker >/dev/null || { curl -fsSL https://get.docker.com | sudo sh; }
  if sudo docker image inspect redroid-pvr:13 >/dev/null 2>&1; then echo "image present"
  elif [ -f "$D/redroid-pvr-13-arm64.tar" ]; then sudo docker load -i "$D/redroid-pvr-13-arm64.tar"
  else (cd "$D/redroid-pvr" && sudo docker build -t redroid-pvr:13 .); fi
  IMAGE=redroid-pvr:13
  if [ "${CODEC2:-0}" = 1 ]; then
    IMAGE=redroid-pvr-c2:13
    sudo docker image inspect $IMAGE >/dev/null 2>&1 || (cd "$D/redroid-pvr-c2" && sudo docker build -t $IMAGE .)
  fi
  # Other Android versions (README 18): IMAGE1 / IMAGE2 choose the image per instance, e.g.
  #   IMAGE1=redroid-pvr:12 IMAGE2=redroid-pvr:17 ./40-board-setup.sh run
  # redroid-pvr:* (Route A) share the pvrsrvkm loaded above; redroid-mesa:* need the open
  # driver instead (BOARD-DAY step 8). Each version comes from redroid-a733-<v>-arm64.tar.zst.
  for img in ${IMAGE1:-} ${IMAGE2:-}; do
    v=${img##*:}
    case "$v" in 12|17) ;; *) continue ;; esac
    sudo docker image inspect "$img" >/dev/null 2>&1 && continue
    command -v zstd >/dev/null || sudo apt-get install -y zstd
    zstd -dc "$D/redroid-a733-$v-arm64.tar.zst" | sudo docker load
  done

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
  # (one Android version only: a /data written by one version must not be used by another)
  if [ "${SHARED_DATA:-0}" = 1 ] && [ "$(echo "${IMAGE1:-$IMAGE}" | sed 's/.*://')" != "$(echo "${IMAGE2:-$IMAGE}" | sed 's/.*://')" ]; then
    echo "SHARED_DATA=1 needs the same Android version in both instances (IMAGE1=${IMAGE1:-$IMAGE}, IMAGE2=${IMAGE2:-$IMAGE})"; exit 1
  fi
  for i in 1 2; do
    if [ $i = 1 ]; then CPUS=1,2,5,6; IMG=${IMAGE1:-$IMAGE}; else CPUS=3,4,5,7; IMG=${IMAGE2:-$IMAGE}; fi
    # A /data written by one Android version must not be reused by another: other images get their own
    DATA=$D/data$i; [ "$IMG" = "$IMAGE" ] || DATA=$D/data$i-${IMG##*:}
    if [ "${SHARED_DATA:-0}" = 1 ]; then   # one image only: the apps are shared between instances
      VOL=(-v "$D/data-base":/data-base -v "$D/data-diff$i":/data-diff); EXTRA=androidboot.use_redroid_overlayfs=1
    else
      VOL=(-v "$DATA":/data); EXTRA=
    fi
    # Route A images declare the IMG gralloc HALs only with this flag (README 18). Give it only
    # when pvrsrvkm is really up: declared without a working driver, the container cannot boot.
    SKU=
    case "$IMG" in redroid-pvr*)
      if [ -d /sys/module/pvrsrvkm ] && [ -e /dev/pvr_sync ]; then SKU=androidboot.product.vendor.sku=pvr
      else echo "  WARNING: pvrsrvkm is not up: android$i starts $IMG without the IMG HALs (software rendering)"; fi ;;
    esac
    sudo docker rm -f android$i 2>/dev/null || true
    sudo docker run -itd --privileged --name android$i \
      --cgroup-parent=android.slice --cpuset-cpus=$CPUS \
      --memory=$LIMIT --memory-swap=$(( ${LIMIT%m} + 1024 ))m \
      "${VOL[@]}" -p $((5554+i)):5555 \
      "$IMG" \
      androidboot.redroid_gpu_mode=host \
      androidboot.redroid_width=720 androidboot.redroid_height=1280 androidboot.redroid_dpi=320 \
      androidboot.redroid_fps=30 androidboot.use_memfd=1 $SKU $EXTRA
  done
  echo "connect: adb connect <board-ip>:5555  and  :5556   (checks: README section 10)"
  ;;
*) echo "usage: $0 kernel|run"; exit 1;;
esac
