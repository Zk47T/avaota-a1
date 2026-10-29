# A733 board day: the first session

> Written for: the person bringing up the first Orange Pi Zero 3W (6 GB) with the redroid + PowerVR farm.
> Prepared in software on 2026-10-28, updated 2026-10-29: apercel first (step 4a, already proven on another Zero 3W, README 16.10), Imagination fw 1.1 (step 4c), open stack (README 16.8). Nothing here has run on our hardware yet.

## 1. What is ready, and what the board must decide

Ready (built or checked without a board):

- Kernel `6.6.98-sun60iw2-redroid`: binder, PSI, zram, docker options, USB Ethernet (`r8152` module). Packages in `out/deploy/debs/`.
- GPU driver `pvrsrvkm` (Android flavour, DDK 24.2@6643903) and the matching firmware `rgx.fw` / `rgx.sh` (36.56.104.183). The driver and blobs match (script 25 PASS).
- redroid 13 with the PowerVR overlay: `redroid-pvr-13-arm64.tar`, 668 MB, built on the stock `redroid/redroid:13.0.0_64only-240527` arm64 image. Its entrypoint is the stock one. **Never booted.**
- Scripts: `40-board-setup.sh` (kernel, run), `45-usb-net.sh` (USB Ethernet), `50-board-report.sh` (PASS / WARN / FAIL report).
- GPU routes, tested in this order (README section 16.6):
  - **apercel** (host, open): CheezeCS's fork of apercel, upstream drm/imagination + 30 backported fixes, with Imagination fw 1.1. **Already works on another Orange Pi Zero 3W** with the same vendor kernel tree (README 16.10). Built by `scripts/22-build-apercel.sh` into `out/apercel/` (run it on the build PC first). This is now the first GPU test.
  - **Route L** (host): the Orange Pi 6.6 PowerVR driver, module `powervr.ko`, with Allwinner's open-source firmware `powervr/rogue_36.56.104.183_v1.fw`. This is the first GPU test. Built 2026-10-28 on the build PC (`out/route-l/`), with three helper modules (`gpu-sched`, `drm_shmem_helper`, `drm_exec`). Not run.
  - **Route A** (redroid): the kit's Android `pvrsrvkm` (DDK 24.2@6643903) with `rgx.fw` / `rgx.sh` 36.56.104.183.
  - **Route M** (later, not this session): the fully open stack, the same one BayLibre builds for the SpacemiT K3, which has the same GPU (README 16.8). Today only its firmware is tested (step 4c).
- Two open-source firmware files for this GPU, same file name (README 16.8):
  - **fw 1.0** build 6852738, from Allwinner's libgpu, sha256 `3974e79f77e0228f6a76d9523bc77a638e679f05e0e97afcb1aa27e7f870c072`. Route L's default (step 4b).
  - **fw 1.1** build 6976702, Imagination's newer build, as used on the K3, sha256 `1db1c399c17401d1f79d46c880db81c724d748c784d4639433b076aba2f9c0d2`. Optional test (step 4c).
- The Debian server image has no PowerVR driver: its kernel config has `CONFIG_AW_DRM_POWERVR` off, and it ships no firmware. The same option is off in every Orange Pi config we checked, so Route L is untested on this board.

Only the board can decide:

- the GPU firmware boots and the GPU powers up on this board (secure reset, clocks, regulator);
- `gpu_config` inside the container selects PowerVR;
- SurfaceFlinger composes on the GPU, and two instances stay stable.

## 2. Hardware to have on the desk

| Item | Why |
|---|---|
| Orange Pi Zero 3W, 6 GB | the pilot board; the 6 GB sizing is in the README (section 8.1) |
| microSD card, A2 / high endurance, 32 GB or more | the OS, Docker and the Android data all live here |
| 5 V USB-C supply, 3 A or more | two Android instances draw real power |
| USB-C Gigabit Ethernet dongle (RTL8153) and cable | the Zero 3W has no Ethernet port |
| 3.3 V USB-UART adapter | the serial console (below); a 5 V adapter can damage the board |

**Serial console** (verified from the Zero 3W schematic, sheet 18): 40-pin header pin 8 is the board's TX, pin 10 is its RX, and pin 6 (or 9) is GND. Connect adapter RX to pin 8, adapter TX to pin 10, GND to pin 6. Use 115200 8N1. Keep this log for every boot: it is the only view of the kernel if the network or the board hangs.

## 3. Steps

1. **Flash the OS.** Write the Orange Pi Debian trixie 1.0.2 server image (`Orangepizero3w_1.0.2_debian_trixie_server_linux6.6.98.7z`; Debian 13.6, kernel 6.6.98-sun60iw2) to the SD card. Check the extracted `.img` against the shipped `.sha`. Power on with the serial adapter attached and log in as the default `orangepi` user.
2. **Back up the stock kernel.** Run `sudo tar -C / -cpf ~/stock-kernel-backup.tar boot usr/lib/modules/6.6.98-sun60iw2`, and copy the tar off the card if you can. The image's apt lists have no Orange Pi kernel index, so this tar is the only rollback.
3. **Copy the kit** (from the build PC, or from the laptop copy). First stage the two firmware files in separate folders, because they have the same name. Both come from `./scripts/00-fetch-sources.sh ref fw`. Replace `<ip>` with the board's address:
   ```bash
   mkdir -p out/fw/1.0 out/fw/1.1
   cp src/libgpu/gpu-firmware/powervr/rogue_36.56.104.183_v1.fw out/fw/1.0/
   cp src/firmware/imagination-fw-1.1/rogue_36.56.104.183_v1.fw out/fw/1.1/
   sha256sum out/fw/*/rogue_36.56.104.183_v1.fw   # 1.0: 3974e79f…  1.1: 1db1c399…
   ./scripts/00-fetch-sources.sh apercel && ./scripts/22-build-apercel.sh   # -> out/apercel/ (4 modules + SHA256SUMS)
   SECURE_CONFIG=0 ./scripts/20-build-pvrsrvkm-android.sh                   # -> out/deploy/lib/modules/pvrsrvkm-android-nosecure.ko (Route A fallback)
   ./scripts/23-build-mesa-android.sh && ./scripts/32-make-redroid-mesa-context.sh            # -> out/redroid-mesa/ (Route M, step 8)
   VARIANT=apercel ./scripts/23-build-mesa-android.sh && VARIANT=apercel ./scripts/32-make-redroid-mesa-context.sh
   rsync -a out/deploy out/route-l out/apercel out/fw out/redroid-mesa out/redroid-mesa-apercel out/redroid-pvr-13-arm64.tar scripts/40-board-setup.sh scripts/45-usb-net.sh scripts/50-board-report.sh orangepi@<ip>:~/farm/
   ```
4. **Install the kernel, then reboot.** `cd ~/farm && ./40-board-setup.sh kernel && sudo reboot`. The package replaces `/boot/uImage`. Watch the serial log: U-Boot must load the uImage and the Zero 3W device tree, and the kernel banner must say `6.6.98-sun60iw2-redroid`. Then `uname -r`.
4a. **GPU first, apercel (README 16.10).** The open driver someone already ran on a Zero 3W. Prove the GPU on the host before the redroid run:
   - Read the power-domain state first: `sudo devmem 0x07065008` (PD 5, GPU_TOP) and `sudo devmem 0x07066008` (PD 6, GPU_CORE). `0x8` means on. `devmem` may need `sudo apt install busybox` or `devmem2`. Read them again after the load.
   - Firmware (apercel's own path): `sudo install -D -m 0644 ~/farm/fw/1.1/rogue_36.56.104.183_v1.fw /lib/firmware/apercel/rogue_36.56.104.183_v1.fw`.
   - Check the files and the kernel: `cd ~/farm/apercel && sha256sum -c SHA256SUMS && uname -r` (must say `6.6.98-sun60iw2-redroid`).
   - Load with `insmod` from `~/farm`, in this order: `sudo insmod gpu-sched.ko && sudo insmod drm_exec.ko && sudo insmod drm_shmem_helper.ko && sudo insmod apercel.ko no_autosuspend=1`.
   - **Don't copy the test modules into `/lib/modules` or run `depmod` for them.** All the GPU drivers match `img,gpu`, so udev would autoload whichever it finds at the next boot: that breaks Route A (`pvrsrvkm`), and a firmware that hangs the board would hang it again on every boot. With `insmod`, a power cycle undoes the test. Likewise, do **not** install apercel's `conf/99-apercel.conf`: it blacklists `pvrsrvkm`, which step 5 needs.
   - Expect in `dmesg`: `FW version v1.1 (build 6976702 OS)`, and a new `/dev/dri/renderD*` node. `cat /sys/kernel/debug/dri/*/name` shows `apercel`. Save `dmesg > ~/farm/apercel-fw1.1.dmesg` and `cat /proc/interrupts | grep -i gpu >> ~/farm/apercel-fw1.1.dmesg`.
   - Optional, 30–45 min: host Vulkan. `sudo ~/farm/armbian-a733-gpu/files/mesa/a733-build-mesa --apercel ~/farm/apercel-src --prefix /opt/mesa-apercel` (copy the sources first, from the build PC: `rsync -a src/apercel/ orangepi@<ip>:~/farm/apercel-src/ && rsync -a src/armbian-a733-gpu orangepi@<ip>:~/farm/`), then `PVR_I_WANT_A_BROKEN_VULKAN_DRIVER=1 VK_ICD_FILENAMES=$(ls /opt/mesa-apercel/share/vulkan/icd.d/*.json) vulkaninfo --summary`. A prefix outside `/usr/local` keeps it away from the system.
   - Unload before 4b: `sudo rmmod apercel`. All open drivers bind `img,gpu`.
4b. **Route L, comparison (README 16.6).** Orange Pi's own, older driver copy:
   - Read the power-domain state: `sudo devmem 0x07065008` (PD 5, GPU_TOP) and `sudo devmem 0x07066008` (PD 6, GPU_CORE). `0x8` means on. `devmem` may need `sudo apt install busybox` or `devmem2`.
   - Install the firmware: `sudo install -D -m 0644 ~/farm/fw/1.0/rogue_36.56.104.183_v1.fw /lib/firmware/powervr/rogue_36.56.104.183_v1.fw`. This is the libgpu file, fw 1.0, sha256 `3974e79f…`.
   - Load with `insmod`, not `depmod` (see 4a): `cd ~/farm/route-l && sha256sum -c SHA256SUMS && sudo insmod powervr.ko`. The three helpers from 4a are still loaded and are the same code. If you skipped 4a, first `sudo insmod gpu-sched.ko`, `drm_exec.ko` and `drm_shmem_helper.ko` from `~/farm/route-l`. `powervr.ko` is built on the build PC against this kernel (`out/route-l/`, not run yet).
   - Check: `dmesg | grep -i -E 'powervr|loaded firmware|FW version|deferring'`, `ls /dev/dri`, and `cat /sys/kernel/debug/dri/*/name` (expect `powervr`).
   - Expect `loaded firmware powervr/rogue_36.56.104.183_v1.fw` and `FW version v1.0 (build 6852738 OS)`, plus a `renderD128` node.
   - Save the result: `dmesg > ~/farm/route-l-fw1.0.dmesg`.
   - If you skip 4c, unload now: `sudo rmmod powervr`. Both drivers bind `img,gpu`, so step 5 needs it gone.
4c. **Optional: Imagination fw 1.1 (README 16.8).** Do this only after 4b, whether 4b passed or failed. Step 4a already runs fw 1.1 with apercel; this tells us whether Orange Pi's older driver copy runs it too. The vendor driver accepts any major-1 file (`FW_MAX_SUPPORTED_MAJOR_VERSION 1`, `pvr_fw.c:26`, minor not checked), so the header passes. What we learn is whether the firmware boots with this driver.
   - Swap the file: `sudo rmmod powervr`, then `sudo install -D -m 0644 ~/farm/fw/1.1/rogue_36.56.104.183_v1.fw /lib/firmware/powervr/rogue_36.56.104.183_v1.fw`, then `sudo dmesg -C && sudo insmod ~/farm/route-l/powervr.ko`.
   - Expect `FW version v1.1 (build 6976702 OS)` and a `renderD128` node. Save `dmesg > ~/farm/route-l-fw1.1.dmesg`.
   - If the board hangs on 1.1, power-cycle. Nothing persistent changed apart from the firmware file, and nothing loads the open drivers at boot.
   - Then put back the file that worked best (1.0 if both work, because Route L was planned with it): `sudo rmmod powervr` (if loaded) and reinstall from `~/farm/fw/1.0/`. Leave `powervr` unloaded for step 5: both drivers bind `img,gpu`.
4d. **Reboot before step 5** (`sudo reboot`). The open-driver tests leave the GPU in an unknown state, and nothing loads them at boot (4a). Never `rmmod` or reload `pvrsrvkm` on a live GPU: on the Zero 3W that hangs the board until a power cycle (README 16.12).
5. **Start the stack.** `./40-board-setup.sh run`. It installs the GPU driver and firmware, loads the image, sets the CPU and memory layout, and starts two instances (`android1` on adb port 5555, `android2` on 5556).
6. **Read the report.** `./50-board-report.sh`. Each line is PASS, WARN or FAIL. The evidence (dmesg, logcat, SurfaceFlinger dump, props) is saved under `~/farm/reports/<time>/`.
7. **Look from the laptop.** `adb connect <ip>:5555` and `adb connect <ip>:5556`, then `adb -s <ip>:5555 shell getprop ro.hardware.egl` and `adb exec-out screencap -p > s1.png`. Keep the serial console attached: with the vendor Linux DDK, a CPU screen grab while the GPU renders can deadlock the kernel (README 16.12). Take one screenshot on an idle screen first, then one while an app animates, and note if the board stops answering.
   - Route A's GPU clock: `dmesg | grep -i 'clk_rate'` should show `change default clk_rate to max opp freq:1008000000`.

8. **Optional, separate boot: Route M, the open stack inside redroid** (README 16.13). It needs apercel on the host instead of `pvrsrvkm`, so keep `pvrsrvkm` from loading at boot, then undo that afterwards:
   - Before rebooting: `sudo mv /etc/modules-load.d/pvrsrvkm.conf ~/farm/ && echo 'blacklist pvrsrvkm' | sudo tee /etc/modprobe.d/farm-route-m.conf && sudo reboot`. After boot, `lsmod | grep pvrsrvkm` must be empty.
   - Host driver: load apercel with fw 1.1 exactly as in step 4a.
   - Image: `cd ~/farm/redroid-mesa && sudo docker build -t redroid-mesa:13 .`. For the variant with CheezeCS's Vulkan 1.3 features, use `~/farm/redroid-mesa-apercel` and tag `redroid-mesa-apercel:13`.
   - One instance: `sudo docker run -itd --privileged --name android-m -p 5557:5555 redroid-mesa:13 androidboot.redroid_gpu_mode=host androidboot.redroid_width=720 androidboot.redroid_height=1280 androidboot.redroid_dpi=320 androidboot.redroid_fps=30 androidboot.use_memfd=1`.
   - Check:
     - `adb connect <ip>:5557`
     - `adb -s <ip>:5557 logcat -d | grep -i -E 'gpu_config|mesa|zink|pvr|vulkan'`: expect `gpu_config: apercel on renderD128 -> Mesa PowerVR Vulkan + Zink`.
     - `adb -s <ip>:5557 shell getprop | grep -E 'hardware.(egl|vulkan|gralloc)|mesa'`
     - `adb -s <ip>:5557 shell dumpsys SurfaceFlinger | grep -i -E 'GLES|zink|PowerVR'`: expect a Zink renderer on the PowerVR device.
     - `adb -s <ip>:5557 shell cmd gpu vkjson | head -50`: the PowerVR Vulkan device.
     - `sys.boot_completed`, and a screenshot.
   - Save: `adb -s <ip>:5557 logcat -d > ~/farm/route-m-logcat.txt`, the `dumpsys SurfaceFlinger` output, and `dmesg | tail -100`.
   - Undo afterwards: `sudo docker rm -f android-m; sudo rm /etc/modprobe.d/farm-route-m.conf; sudo mv ~/farm/pvrsrvkm.conf /etc/modules-load.d/ && sudo reboot`.

## 4. How to read the result

- **PASS** everything in section 2 of the report, `sys.boot_completed=1`, and `ro.hardware.egl=POWERVR_ROGUE`: the GPU is in use.
- **WARN** `PowerVR not selected`: the phones run, but on software rendering. Check `dmesg` for the GPU errors first.
- **FAIL** anything else: send the report folder.

Expected values, for comparison: the DRM device is named `pvr`; SurfaceFlinger shows `PowerVR B-Series BXM-4-64` with `OpenGL ES 3.2 build 24.2@6643903`.

For Route L (step 4b), the DRM name is `powervr` and the log shows `loaded firmware powervr/rogue_36.56.104.183_v1.fw` and `FW version v1.0 (build 6852738 OS)`; with step 4c's file it shows `FW version v1.1 (build 6976702 OS)`. If the firmware loads but there is no `renderD128` node, the probe failed after the load: read `dmesg` from that point.

## 5. If something fails (first moves)

| Symptom | First move |
|---|---|
| Nothing on the serial console | Check TX and RX are crossed, 115200 8N1, GND on pin 6 or 9, adapter at 3.3 V. |
| No boot after step 4 | Reflash the stock image to the SD card. The kernel package only touched `/boot/uImage`. Keep the serial log. |
| `pvrsrvkm` does not load | `dmesg | grep -i pvr`. Check `uname -r` matches `6.6.98-sun60iw2-redroid`. |
| GPU errors or firmware timeout | Keep the dmesg lines from `50-board-report.sh`. Do not retry in a loop. |
| `no DRM device named 'pvr'` | `sudo mount -t debugfs none /sys/kernel/debug`, then run the report again. |
| Containers do not reach `boot_completed` | Check `docker logs android1` and `adb logcat`. Try the software fallback below. |
| Second instance slow or killed | Stop it (`sudo docker rm -f android2`), check `free -m` and `docker stats`. |
| USB Ethernet gives no link | `lsusb`, then `dmesg | grep -i -E "rtl|r8152"`, then `sudo modprobe r8152`. |
| `deferring` in dmesg after `insmod powervr.ko` | The firmware file is missing or in the wrong path. Check `/lib/firmware/powervr/rogue_36.56.104.183_v1.fw` (sha256 `3974e79f…`). |
| `Unsupported fw info version 2` or `FW info format mismatch` | Wrong firmware file. The Radxa and Android `rgx.fw` copies are info v2 and are not for Route L. |
| `FW built for incorrect GPU ID` | Firmware for another BVNC. Route L needs 36.56.104.183. |
| `Unsupported FW version 1.1 ...` (step 4c) | The driver refuses the 1.1 header. Not expected with the Orange Pi driver (it checks only major ≤ 1). Keep the line, go back to fw 1.0. |
| fw 1.1 loads, then firmware timeout or GPU errors (step 4c) | The 1.1 firmware interface doesn't match this 6.6 driver. Keep `~/farm/route-l-fw1.1.dmesg` and go back to fw 1.0. Route M would then need a newer driver (apercel or mainline). |
| apercel: `vulkaninfo` finds no device although the module is loaded | Mesa looks for the DRM driver name `apercel`. The Mesa build lacks apercel's patch; check `strings libvulkan_powervr_mesa.so | grep -x apercel`. |
| apercel: `Unknown symbol drm_sched_*` (or `drm_exec_*`, `drm_gem_shmem_*`) | The three helper modules from `out/apercel/` are missing or not loaded first. Load them in the order of step 4a. |
| apercel: firmware `deferring` or `not found` | apercel reads `/lib/firmware/apercel/`, not `/lib/firmware/powervr/`. |
| `Unknown GPU! Set 'exp_hw_support' to bypass this check.` | Only with a mainline-based driver (apercel, or a mainline build), never with Route L's Orange Pi driver. 36.56.104.183 is not in mainline's support list yet. Reload with `exp_hw_support=1` (for example `sudo modprobe powervr exp_hw_support=1`); the driver then warns `Running on unknown hardware; expect issues.` |
| Board hangs when the GPU starts (Route A) | Likely an SError from a blocked secure-register write. Keep the serial log, power-cycle, then try the fallback without our secure-reset port: `sudo install -D -m644 ~/farm/deploy/lib/modules/pvrsrvkm-android-nosecure.ko /lib/modules/$(uname -r)/extra/pvrsrvkm.ko && sudo depmod -a && sudo reboot`. Radxa's Linux DDK, which has no such writes, runs on the Zero 3W. |
| Board hangs during a screenshot or scrcpy (Route A) | The vendor-DDK deadlock other Zero 3W users hit with a live compositor (README 16.12). Power-cycle, keep the serial log (look for `mutex_spin_on_owner`), and note what was on screen. |
| PD 5 or PD 6 reads `0x0` after probe | The power domain is off, so the GPU is unpowered. Check the PCK-600 probe in `dmesg`. |
| `Unknown symbol drm_sched_*` (or `drm_exec_*`, `drm_gem_shmem_*`) from `insmod powervr.ko` | The three helper modules are not loaded. `insmod` them first (step 4a or 4b). |
| `Invalid module format` / `version magic` from `insmod`, or the same in `dmesg` | The module was built for another kernel. `readelf -p .modinfo powervr.ko` (or `apercel.ko`) must show `vermagic=6.6.98-sun60iw2-redroid`, matching `uname -r`. |

**Software fallback (GPU not working).** Edit `40-board-setup.sh`: change `androidboot.redroid_gpu_mode=host` to `guest` in the `docker run` lines, then `sudo docker rm -f android1 android2` and `./40-board-setup.sh run`. Everything except the GPU still gets tested.

**Rollback.** `sudo tar -C / -xpf ~/stock-kernel-backup.tar && sudo reboot`. If the board will not boot at all, reflash the stock image (step 1).

## 6. What to send back

- the report folder `~/farm/reports/<time>/`;
- the serial log of the first boot after step 4, and of the first boot after step 5 if there were problems;
- the output of `uname -r` and `sudo dmesg | tail -100` if anything failed.
- For Route L: `dmesg | grep -i -E 'powervr|rogue|FW version|deferring|loaded firmware'`, `cat /sys/kernel/debug/dri/*/name`, and the PD 5 and PD 6 `devmem` readbacks.
- For each driver and firmware tried: `~/farm/apercel-fw1.1.dmesg`, `~/farm/route-l-fw1.0.dmesg` and, if step 4c ran, `~/farm/route-l-fw1.1.dmesg`, plus one line saying which file is installed at the end.
- The PD 5 and PD 6 readbacks before and after each load (they decide whether an upstream A733 GPU node needs one power domain or two, README 16.10).
- If step 8 ran: `~/farm/route-m-logcat.txt`, the SurfaceFlinger dump, and which image (base or apercel variant) booted.
- On a PC with internet, run `python3 -I scripts/60-mainline-watch.py` (README 16.9) and note anything marked `*` or `NEW`. Upstream may have moved since 2026-10-29.

## 7. Not in scope for this session

- eMMC: not needed for the SD boot. For eMMC day, the device tree is prepared: `out/zero3w-emmc/sun60i-a733-orangepi-zero3w-emmc.dtb`, with the change in `config/zero3w-emmc-supplies.patch`. VCC comes from DC-DC1 at 3.3 V (`reg_dc1sw2`, the SD card's rail). VCCQ comes from `reg_cldo1` at 1.8 V; confirm it with a meter on the eMMC VCCQ pad before the first boot. The stock Debian device tree already enables the eMMC controller (`sdmmc@4022000`), so an empty socket is probed on every boot with the stock tree too. The eMMC tree only adds the rails. Keep the stock tree for the SD-first boot, and install the eMMC tree once a chip is fitted and VCCQ is confirmed.
- JTAG: not needed now. The schematic routes the JTAG pins to the 40-pin header (PB route), but boot0 and pin muxing are not verified yet.

## 8. Reference images (not for the farm)

- **Radxa A733 Bullseye KDE image** (`radxa-a733_bullseye_kde_r2.output_512.img.xz`, sha256 `1b5604fe…`, kernel 5.15.147-14-a733). It ships a prebuilt Linux GPU stack: the DKMS package `img-bxm-dkms` 0.1.0-2, a built `pvrsrvkm.ko.xz` for its kernel (DDK 24.2@6603887, Linux WS build), the IMG user-space libraries (24.2.6603887), and firmware 36.56.104.183. Its `rgx.sh` is byte-identical to the kit's; its `rgx.fw` is not (`43eb5d05…` against the kit's Android copy `11e08779…`). Its EGL is Mesa's. Its sunxi layer defines the DRM_CTRL register, but I found no write to it and no SMC secure-release call, so it doesn't settle the secure-reset question. Use it to compare the Linux driver and its start sequence. Do not use it as a base: the kernel is 5.15.
- **Orange Pi Android 13 pack** (`OrangePiZero3W_A733_Android13_lcd_v1.0`): Android-flavour `pvrsrvkm`, DDK 24.2@6643903 strings, firmware 36.56.104.183, kernel 5.15.119, `buildvariant=userdebug`. Use it for the Android blobs and the device tree. Do not flash it to the farm.
- **Allwinner libgpu** (`tina5.0_aiot/product/linux/external/libgpu`, commit `144487e8`): the open-source firmware `powervr/rogue_36.56.104.183_v1.fw` (fw 1.0) for Route L, and the DDK 6603887 userspace libraries (for the DDK kernel driver, not Route L). Mirror it with the rest.
- **CheezeCS/armbian-a733-gpu** (`src/armbian-a733-gpu` @ `6960be50`, fetch group `apercel`): Armbian for the Zero 3W with apercel, fw 1.1 and Mesa 26.3. Its `docs/troubleshooting.md` lists every problem they hit on this board. Its `files/mesa/a733-build-mesa` builds Mesa with the apercel patch on the board or cross on amd64 Debian trixie.
- **BayLibre SpacemiT K3 AOSP** (`src/baylibre-k3` @ `06c4578e`, `src/baylibre-common` @ `755c243b`, fetch group `fw`): Android 17 on the same GPU with upstream `drm/imagination` + Imagination fw 1.1 + Mesa (PowerVR Vulkan + Zink) + minigbm `gbm_mesa`. It is the template for Route M (README 16.8). It is build-green but not yet validated on hardware, and it is riscv64, so nothing in it runs here as is.
- Mirror the Radxa apt repo (`radxa-repo.github.io/a733-bullseye`) and keep the Orange Pi pack, before the links disappear.
