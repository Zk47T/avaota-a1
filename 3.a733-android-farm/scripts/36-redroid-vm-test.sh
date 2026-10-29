#!/usr/bin/env bash
# Boot the farm's redroid images in an emulated arm64 VM on the build PC, without a board:
# Ubuntu 24.04 arm64 (binder_linux + docker) under QEMU TCG, each image in software
# rendering (guest mode). Shows whether an image boots at all, how long boot takes under
# emulation, its memory use, and, for the GPU overlays, whether Android's real dynamic
# linker loads the vendor libraries in the sphal namespace. No GPU path is exercised.
# README section 18.
#   ./scripts/36-redroid-vm-test.sh setup               QEMU container, cloud image, disk, cloud-init seed
#   ./scripts/36-redroid-vm-test.sh start               boot the VM and wait for docker + binder
#   ./scripts/36-redroid-vm-test.sh load IMAGE...       stream images from this PC's docker into the VM
#   ./scripts/36-redroid-vm-test.sh test IMAGE [pvr|mesa] [PORT]   boot test (+ link test of that route)
#   ./scripts/36-redroid-vm-test.sh safety IMAGE [PORT]  reboot it with /data as a volume: must not touch the host
#   ./scripts/36-redroid-vm-test.sh sku IMAGE [PORT]     Route A image with sku=pvr: IMG HALs declared? (no GPU: boot stalls)
#   ./scripts/36-redroid-vm-test.sh stop
# Results: out/vm-test/<image>/ (summary.txt, logcat, docker log, meminfo); safety: out/vm-test/safety-<image>.txt.
set -uo pipefail
FARM=$(cd "$(dirname "$0")/.." && pwd)
VM=${VM:-$FARM/out/vm}
R=$FARM/out/vm-test
SSHV=(ssh -i "$VM/vm_key" -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 zk47@127.0.0.1)
vm() { "${SSHV[@]}" "$@"; }

case "${1:-}" in
setup)
  set -e
  docker image inspect a733-qemu:trixie >/dev/null 2>&1 || docker build --platform linux/amd64 -q -t a733-qemu:trixie - <<'DF'
FROM debian:trixie
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      qemu-system-arm qemu-efi-aarch64 qemu-utils ipxe-qemu \
 && rm -rf /var/lib/apt/lists/*
DF
  mkdir -p "$VM"; cd "$VM"
  U=https://cloud-images.ubuntu.com/noble/current
  [ -f noble-arm64.img ] || curl -fL -o noble-arm64.img "$U/noble-server-cloudimg-arm64.img"
  curl -fsSL "$U/SHA256SUMS" | grep ' \*noble-server-cloudimg-arm64.img$' \
    | sed 's/\*noble-server-cloudimg-arm64.img/noble-arm64.img/' | sha256sum -c
  [ -f vm_key ] || ssh-keygen -q -t ed25519 -N "" -C a733-vm -f vm_key
  cat > user-data <<UD
#cloud-config
hostname: a733-vm
users:
  - name: zk47
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - $(cat vm_key.pub)
ssh_pwauth: false
package_update: true
packages: [docker.io, adb, zstd]
write_files:
  - path: /etc/modules-load.d/binder.conf
    content: "binder_linux\n"
  - path: /etc/modprobe.d/binder.conf
    content: "options binder_linux devices=binder,hwbinder,vndbinder\n"
runcmd:
  - [sh, -c, "apt-get install -y linux-modules-extra-\$(uname -r) && modprobe binder_linux devices=binder,hwbinder,vndbinder"]
  - [usermod, -aG, docker, zk47]
  - [sh, -c, "touch /var/lib/a733-vm-ready"]
UD
  printf 'instance-id: a733-vm-1\nlocal-hostname: a733-vm\n' > meta-data
  genisoimage -quiet -output seed.iso -volid cidata -joliet -rock user-data meta-data
  docker run --rm --platform linux/amd64 -v "$VM:/vm" a733-qemu:trixie sh -c "
    [ -f /vm/disk.qcow2 ] || qemu-img create -q -f qcow2 -F qcow2 -b /vm/noble-arm64.img /vm/disk.qcow2 60G
    [ -f /vm/AAVMF_VARS.fd ] || cp /usr/share/AAVMF/AAVMF_VARS.fd /vm/
    chown -R $(id -u):$(id -g) /vm"
  echo "setup done: $VM"
  ;;
start)
  docker rm -f a733-vm >/dev/null 2>&1
  # TCG, one host thread per vCPU; ports only on localhost. 10 of the PC's 12 cores, 16 GB.
  # QEMU runs as this user, so the console and monitor sockets in $VM stay usable from here.
  # Host network on purpose: through docker's port mapping, forwarded connections reach the
  # guest from 172.17.0.x, the same subnet as the guest's own docker0, and its replies never
  # leave the guest. From 127.0.0.1, QEMU presents them as its virtual host 10.0.2.2.
  docker run -d --name a733-vm --platform linux/amd64 --user "$(id -u):$(id -g)" --network host -v "$VM:/vm" a733-qemu:trixie \
    qemu-system-aarch64 -machine virt,gic-version=3 -cpu max,pauth-impdef=on -smp "${VM_CPUS:-10}" -m "${VM_MEM:-16G}" \
      -accel tcg,thread=multi,tb-size=1024 \
      -drive if=pflash,format=raw,readonly=on,file=/usr/share/AAVMF/AAVMF_CODE.fd \
      -drive if=pflash,format=raw,file=/vm/AAVMF_VARS.fd \
      -drive if=virtio,format=qcow2,file=/vm/disk.qcow2,cache=unsafe \
      -drive if=virtio,format=raw,file=/vm/seed.iso,readonly=on \
      -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2222-:22 -device virtio-net-pci,netdev=n0 -device virtio-rng-pci \
      -chardev socket,id=con,path=/vm/console.sock,server=on,wait=off,logfile=/vm/console.log \
      -serial chardev:con -monitor unix:/vm/monitor.sock,server=on,wait=off -display none >/dev/null
  echo "booting the VM (first boot runs cloud-init and installs docker: 15-30 min under emulation)"
  for _ in $(seq 1 180); do
    vm 'test -f /var/lib/a733-vm-ready && lsmod | grep -q binder_linux && docker info >/dev/null 2>&1' 2>/dev/null && break
    sleep 20
  done
  vm 'uname -r; grep binder /proc/filesystems; docker --version' || { echo "VM not ready, see $VM/console.log"; exit 1; }
  ;;
load)
  shift   # one stream: layers shared by a base and its overlays cross only once. The platform
  # matters: multi-arch images pulled for arm64 lack the other platforms' content, and a plain
  # save then fails with "content digest ... not found".
  docker save --platform linux/arm64 "$@" | vm docker load
  ;;
test)
  IMG=$2; ROUTE=${3:-}; PORT=${4:-5555}; NAME=t$PORT
  O=$R/$(echo "$IMG" | tr '/:' '__'); rm -rf "$O"; mkdir -p "$O"
  # BOOT_ARGS adds start arguments, e.g. BOOT_ARGS=androidboot.product.vendor.sku=pvr.
  # The emulated CPU is 10-20x slower than a board: without a longer system_server watchdog,
  # Android 17 is killed by it again and again while booting (redroid passes ro.* args as props).
  vm "docker rm -f $NAME >/dev/null 2>&1; docker run -itd --privileged --name $NAME -p $PORT:5555 $IMG \
      androidboot.redroid_gpu_mode=guest androidboot.use_memfd=1 \
      androidboot.redroid_width=720 androidboot.redroid_height=1280 androidboot.redroid_dpi=320 \
      ro.hw_timeout_multiplier=${HW_TIMEOUT_MULTIPLIER:-10} ${BOOT_ARGS:-} >/dev/null" \
    || { echo "image: $IMG"; echo "docker run FAILED (image loaded?)"; } > "$O/summary.txt"
  # keep the whole log from the first second: logd's buffers wrap long before a slow boot ends
  vm "rm -f /tmp/$NAME-logcat.txt; nohup sh -c 'while [ \"\$(docker inspect -f {{.State.Status}} $NAME 2>/dev/null)\" = running ]; do \
      docker exec $NAME /system/bin/logcat -b all -v threadtime >> /tmp/$NAME-logcat.txt 2>/dev/null; sleep 1; done' >/dev/null 2>&1 &"
  t0=$(date +%s); boot=; state=
  for _ in $(seq 1 ${BOOT_POLLS:-150}); do       # 150 x 20 s = 50 min
    sleep 20
    state=$(vm "docker inspect -f '{{.State.Status}}/{{.State.ExitCode}}' $NAME" 2>/dev/null)
    [ "${state%/*}" = running ] || break
    b=$(vm "adb connect localhost:$PORT >/dev/null 2>&1; timeout 20 adb -s localhost:$PORT shell getprop sys.boot_completed 2>/dev/null" | tr -d '\r')
    [ "$b" = 1 ] && { boot=$(( $(date +%s) - t0 )); break; }
  done
  A="timeout 60 adb -s localhost:$PORT"
  # adb waits for a missing device forever: only use it if the container is up and connected
  online=$(vm "timeout 10 adb -s localhost:$PORT get-state 2>/dev/null" | tr -d '\r')
  {
    echo "container: ${state:-none}"
    if [ "$online" != device ] && [ "${state%/*}" = running ]; then
      echo "adb: not connected (boot did not reach adbd)"
      vm "docker exec $NAME /system/bin/logcat -d 2>/dev/null" | grep -m3 -E 'Waited one second for|getService: Trying again for' | sed 's/^/waiting: /'
      vm "docker exec $NAME /system/bin/logcat -d 2>/dev/null" > "$O/logcat.txt" 2>&1
    elif [ "$online" != device ]; then echo "adb: not connected (no Android userspace reached adbd)"; fi
    echo "image: $IMG"
    echo "boot_completed: $([ -n "$boot" ] && echo "yes after $boot s (emulated)" || echo NO)"
    if [ "$online" = device ]; then
      echo "android: $(vm "$A shell getprop ro.build.version.release" | tr -d '\r') sdk $(vm "$A shell getprop ro.build.version.sdk" | tr -d '\r')"
      echo "egl/gralloc/vulkan: $(vm "$A shell 'getprop ro.hardware.egl; getprop ro.hardware.gralloc; getprop ro.hardware.vulkan'" | tr -d '\r' | tr '\n' ' ')"
      echo "container memory: $(vm "docker stats --no-stream --format '{{.MemUsage}}' $NAME")"
      vm "$A shell dumpsys meminfo" | tr -d '\r' | grep -E '^ *(Total RAM|Used RAM|Free RAM|Lost RAM)' | sed 's/^ */meminfo /'
      echo "allocator services: $(vm "$A shell 'getprop | grep -E \"init.svc.vendor.(gralloc|graphics.allocator)\"'" | tr -d '\r' | tr '\n' ' ')"
      # a boot stuck on a declared HAL that never starts shows up here
      vm "timeout 60 adb -s localhost:$PORT logcat -d" | grep -m3 -E 'Waited one second for|getService: Trying again for' | sed 's/^/waiting: /'
      # networking as an app sees it (the VM reaches the internet through QEMU's NAT)
      for t in 8.8.8.8 dns.google; do
        vm "$A shell ping -c 1 -W 5 $t" 2>&1 | grep -q ' 0% packet loss' && echo "network: ping $t ok" || echo "network: ping $t FAILED"
      done
      echo "netd iptables errors: $(vm "timeout 60 adb -s localhost:$PORT logcat -d" | grep -c 'IptablesRestoreController: iptables error')"
      # audioserver without a primary output means no sound for apps (README 18.3, A17 fix 9)
      a=$(vm "$A shell dumpsys media.audio_policy" 2>/dev/null | tr -d '\r' | grep -m1 'Primary Output')
      echo "audio: ${a:-NO primary output (AudioPolicyManager not initialised)}"
      echo "system_server watchdog kills: $(vm "timeout 60 adb -s localhost:$PORT logcat -d" | grep -c 'WATCHDOG KILLING SYSTEM PROCESS')"
    fi
  } >> "$O/summary.txt" 2>&1
  vm "docker logs $NAME" > "$O/docker.log" 2>&1
  vm "cat /tmp/$NAME-logcat.txt" > "$O/logcat-full.txt" 2>/dev/null   # from the first second
  if [ "$online" = device ]; then
    vm "timeout 120 adb -s localhost:$PORT logcat -d" > "$O/logcat.txt" 2>&1
    vm "$A shell dumpsys meminfo" > "$O/meminfo.txt" 2>&1
  fi
  [ -n "$boot" ] || vm "sudo dmesg | tail -200" > "$O/vm-dmesg.txt" 2>&1   # init writes to kmsg
  if [ -n "$ROUTE" ] && [ -n "$boot" ]; then
    case "$ROUTE" in
      pvr)  LIBS="/vendor/lib64/egl/libEGL_POWERVR_ROGUE.so /vendor/lib64/egl/libGLESv1_CM_POWERVR_ROGUE.so \
                  /vendor/lib64/egl/libGLESv2_POWERVR_ROGUE.so /vendor/lib64/hw/vulkan.powervr.so \
                  /vendor/lib64/hw/gralloc.powervr.so /vendor/lib64/hw/android.hardware.graphics.mapper@4.0-impl.so"
            EXE=/vendor/bin/hw/android.hardware.graphics.allocator@4.0-service ;;
      mesa) LIBS="/vendor/lib64/egl/libEGL_mesa.so /vendor/lib64/egl/libGLESv1_CM_mesa.so /vendor/lib64/egl/libGLESv2_mesa.so \
                  /vendor/lib64/hw/vulkan.mesa.so /vendor/lib64/libgallium_dri.so /vendor/lib64/gbm/dri_gbm.so \
                  /vendor/lib64/hw/gralloc.gbm.so"
            EXE= ;;
    esac
    cat "$R/sphal_loadtest" | vm "cat > /tmp/sphal_loadtest && chmod 755 /tmp/sphal_loadtest && docker cp /tmp/sphal_loadtest $NAME:/system/bin/sphal_loadtest"
    { echo "== runtime sphal load test ($ROUTE)"; vm "$A shell /system/bin/sphal_loadtest $LIBS" | tr -d '\r'
      if [ -n "$EXE" ]; then   # a vendor executable that fails to link prints CANNOT LINK EXECUTABLE
        echo "== vendor executable link test: $EXE"
        vm "$A shell 'timeout 5 $EXE 2>&1 | head -3; echo exit=\$?'" | tr -d '\r'
      fi; } >> "$O/summary.txt" 2>&1
  fi
  vm "docker rm -f $NAME >/dev/null 2>&1"
  cat "$O/summary.txt"
  ;;
sku)   # Route A's switch (README 18.1): with androidboot.product.vendor.sku=pvr, Android must read
  # manifest_pvr.xml, so lshal lists the IMG allocator 4.0 as declared and gpu_config takes the
  # PowerVR path. There is no GPU here, so SurfaceFlinger cannot start and boot stalls: expected.
  IMG=$2; PORT=${3:-5570}; NAME=sku$PORT; mkdir -p "$R"
  vm "docker rm -f $NAME >/dev/null 2>&1; sudo dmesg -C; docker run -itd --privileged --name $NAME -p $PORT:5555 $IMG \
      androidboot.redroid_gpu_mode=guest androidboot.use_memfd=1 androidboot.redroid_width=720 \
      androidboot.redroid_height=1280 androidboot.redroid_dpi=320 ro.hw_timeout_multiplier=10 \
      androidboot.product.vendor.sku=pvr >/dev/null"
  # docker exec, not adb: with boot stalled on purpose, redroid may never start adbd
  X="docker exec $NAME /system/bin/sh -c"
  st=running
  for _ in $(seq 1 60); do   # until init has run gpu_config (the vendor props are set)
    sleep 20
    st=$(vm "docker inspect -f '{{.State.Status}}/{{.State.ExitCode}}' $NAME" 2>/dev/null)
    [ "${st%/*}" = running ] || break
    [ -n "$(vm "$X 'getprop ro.hardware.egl'" 2>/dev/null)" ] && break
  done
  if [ "${st%/*}" != running ]; then   # init gave up (e.g. an unparsable manifest_pvr.xml)
    { echo "image: $IMG (started with androidboot.product.vendor.sku=pvr)"
      echo "container ended early: $st"
      vm "sudo dmesg | grep -E 'VINTF parse error|critical process|Got shutdown_command' | tail -4"
    } | tee "$R/sku-$(echo "$IMG" | tr '/:' '__').txt"
    vm "docker rm -f $NAME >/dev/null 2>&1"; exit 1
  fi
  sleep 120   # let the HALs start (or fail)
  { echo "image: $IMG (started with androidboot.product.vendor.sku=pvr)"
    echo "ro.boot.product.vendor.sku: $(vm "$X 'getprop ro.boot.product.vendor.sku'")"
    echo "ro.hardware.egl: $(vm "$X 'getprop ro.hardware.egl'")"
    echo "IMG allocator service: $(vm "$X 'getprop init.svc.vendor.gralloc-4-0'")"
    echo "-- lshal, graphics HALs:"; vm "$X 'lshal -i 2>/dev/null | grep -i -E \"graphics.(allocator|mapper)\"'"
    echo "-- gpu_config:"; vm "$X 'logcat -d | grep -i gpu_config | head -5'"
    echo "-- waiting for:"; vm "$X 'logcat -d | grep -E \"Trying again for|Waited one second for\" | head -3'"
  } | tee "$R/sku-$(echo "$IMG" | tr '/:' '__').txt"
  vm "docker rm -f $NAME >/dev/null 2>&1"
  ;;
safety)   # does rebooting a container touch the host? (README 18.3) The farm's setup, /data as a
  # volume, then 'adb reboot'. A canary process on the VM host must survive, and the kernel log
  # must show no sysrq. Runs detached in the VM: a bad image kills every host process, ssh too.
  IMG=$2; PORT=${3:-5560}; mkdir -p "$R"
  vm 'cat > /tmp/reboot-safety.sh; chmod +x /tmp/reboot-safety.sh' <<'SH'
#!/usr/bin/env bash
IMG=$1; PORT=$2; N=rs$PORT
exec > /tmp/rs-$PORT.log 2>&1
docker rm -f $N >/dev/null 2>&1; sudo rm -rf /tmp/$N-data; mkdir -p /tmp/$N-data
setsid sleep 100000 >/dev/null 2>&1 < /dev/null & CANARY=$!
echo "image $IMG, canary pid $CANARY"
docker run -itd --privileged --name $N -v /tmp/$N-data:/data -p $PORT:5555 "$IMG" \
  androidboot.redroid_gpu_mode=guest androidboot.use_memfd=1 \
  androidboot.redroid_width=720 androidboot.redroid_height=1280 androidboot.redroid_dpi=320 \
  ro.hw_timeout_multiplier=10 >/dev/null
t0=$(date +%s); boot=
for _ in $(seq 1 300); do
  sleep 10
  [ "$(docker inspect -f '{{.State.Status}}' $N)" = running ] || break
  adb connect localhost:$PORT >/dev/null 2>&1
  [ "$(timeout 20 adb -s localhost:$PORT shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ] && { boot=$(( $(date +%s) - t0 )); break; }
done
echo "boot_completed: ${boot:-NO} s; container $(docker inspect -f '{{.State.Status}}/{{.State.ExitCode}}' $N)"
sudo dmesg -C
if [ -n "$boot" ]; then
  echo "== adb reboot"
  timeout 30 adb -s localhost:$PORT reboot
  for _ in $(seq 1 60); do sleep 5; [ "$(docker inspect -f '{{.State.Status}}' $N)" = running ] || break; done
  echo "container after reboot: $(docker inspect -f '{{.State.Status}}/{{.State.ExitCode}}' $N)"
fi
kill -0 $CANARY 2>/dev/null && echo "host canary: ALIVE" || echo "host canary: KILLED"
kill $CANARY 2>/dev/null; docker rm -f $N >/dev/null 2>&1
echo "== DONE"
SH
  vm "nohup setsid /tmp/reboot-safety.sh $IMG $PORT >/dev/null 2>&1 < /dev/null &"
  sleep 30
  # [r]: the pattern must not match the remote shell that runs pgrep
  for _ in $(seq 1 200); do vm "pgrep -f '[r]eboot-safety.sh $IMG' >/dev/null" 2>/dev/null || break; sleep 20; done
  sleep 10
  { vm "cat /tmp/rs-$PORT.log"; echo "-- kernel log since the reboot:"
    vm "sudo dmesg | grep -i -E 'sysrq|Terminate All|Kill All'" || echo "no sysrq"; } \
    | tee "$R/safety-$(echo "$IMG" | tr '/:' '__').txt"
  ;;
stop)   # clean guest shutdown through the QEMU monitor, then remove the container
  printf 'system_powerdown\n' | socat - "UNIX-CONNECT:$VM/monitor.sock" >/dev/null 2>&1 \
    || python3 -I -c "import socket,sys; s=socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); s.send(b'system_powerdown\n')" "$VM/monitor.sock"
  for _ in $(seq 1 30); do [ "$(docker inspect -f '{{.State.Running}}' a733-vm 2>/dev/null)" = true ] || break; sleep 10; done
  docker rm -f a733-vm >/dev/null 2>&1 ;;
*) sed -n '2,17p' "$0"; exit 2 ;;
esac
