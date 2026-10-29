#!/usr/bin/env bash
# RUN ON THE ORANGE PI: where the eMMC/SD space goes, and how fast the farm
# writes to flash (README 8.4). Run once after setup and again after a day of
# use: GB/day decides how long a 16 GB eMMC lasts. Changes nothing.
#   ./55-storage-report.sh            (pass an app package to size, e.g. com.zhiliaoapp.musically)
set -uo pipefail
D=${FARM_DIR:-$HOME/farm}
PKGS=${*:-com.zhiliaoapp.musically com.ss.android.ugc.trill com.instagram.android}

echo "== space"
df -h / | tail -1
sudo docker system df 2>/dev/null
for d in "$D"/data* ; do [ -d "$d" ] && sudo du -sh "$d"; done
for c in $(sudo docker ps --format '{{.Names}}' | grep -E '^android'); do
  echo "-- $c"
  sudo docker exec "$c" sh -c 'du -sh /data/app /data/dalvik-cache /data/data 2>/dev/null'
  for p in $PKGS; do
    sudo docker exec "$c" sh -c "[ -d /data/data/$p ] && du -sh /data/data/$p /data/data/$p/cache \
      /sdcard/Android/data/$p 2>/dev/null"
  done
done

echo "== writes to flash since boot"
dev=$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" 2>/dev/null)
if [ -n "$dev" ] && [ -r "/sys/block/$dev/stat" ]; then
  sect=$(awk '{print $7}' "/sys/block/$dev/stat")
  up=$(awk '{print $1}' /proc/uptime)
  awk -v s="$sect" -v u="$up" -v d="$dev" 'BEGIN {
    gb = s * 512 / 1e9; days = u / 86400
    printf "%s: %.2f GB written in %.1f h -> %.1f GB/day\n", d, gb, u / 3600, gb / days }'
  # eMMC wear estimate (JEDEC EXT_CSD): life time 0x01 = 0-10% used ... 0x0b = beyond limit
  if [[ $dev == mmcblk* ]] && command -v mmc >/dev/null; then
    sudo mmc extcsd read "/dev/$dev" | grep -iE 'LIFE_TIME_EST|PRE_EOL'
  elif [[ $dev == mmcblk* ]]; then
    echo "(apt install mmc-utils for the eMMC wear estimate)"
  fi
else
  echo "root device not found"
fi
