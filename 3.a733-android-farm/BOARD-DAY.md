# A733 board day: the first session

> Written for: the person bringing up the first Orange Pi Zero 3W (6 GB) with the redroid + PowerVR farm.
> Prepared in software on 2026-10-28. Nothing here has run on hardware yet.

## 1. What is ready, and what the board must decide

Ready (built or checked without a board):

- Kernel `6.6.98-sun60iw2-redroid`: binder, PSI, zram, docker options, USB Ethernet (`r8152` module). Packages in `out/deploy/debs/`.
- GPU driver `pvrsrvkm` (Android flavour, DDK 24.2@6643903) and the matching firmware `rgx.fw` / `rgx.sh` (36.56.104.183). The driver and blobs match (script 25 PASS).
- redroid 13 with the PowerVR overlay: `redroid-pvr-13-arm64.tar`, 668 MB, built on the stock `redroid/redroid:13.0.0_64only-240527` arm64 image. Its entrypoint is the stock one. **Never booted.**
- Scripts: `40-board-setup.sh` (kernel, run), `45-usb-net.sh` (USB Ethernet), `50-board-report.sh` (PASS / WARN / FAIL report).
- Two GPU routes, tested in this order (README section 16.6):
  - **Route L** (host): the Orange Pi 6.6 PowerVR driver, module `powervr.ko`, with Allwinner's open-source firmware `powervr/rogue_36.56.104.183_v1.fw`. This is the first GPU test. Built 2026-10-28 on the build PC (`out/route-l/`), with three helper modules (`gpu-sched`, `drm_shmem_helper`, `drm_exec`). Not run.
  - **Route A** (redroid): the kit's Android `pvrsrvkm` (DDK 24.2@6643903) with `rgx.fw` / `rgx.sh` 36.56.104.183.
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
3. **Copy the kit** (from the build PC, or from the laptop copy). Replace `<ip>` with the board's address:
   ```bash
   rsync -a out/deploy out/route-l out/redroid-pvr-13-arm64.tar scripts/40-board-setup.sh scripts/45-usb-net.sh scripts/50-board-report.sh orangepi@<ip>:~/farm/
   ```
4. **Install the kernel, then reboot.** `cd ~/farm && ./40-board-setup.sh kernel && sudo reboot`. The package replaces `/boot/uImage`. Watch the serial log: U-Boot must load the uImage and the Zero 3W device tree, and the kernel banner must say `6.6.98-sun60iw2-redroid`. Then `uname -r`.
4b. **GPU first, Route L (README 16.6).** Prove the GPU on the host before the redroid run:
   - Read the power-domain state: `sudo devmem 0x07065008` (PD 5, GPU_TOP) and `sudo devmem 0x07066008` (PD 6, GPU_CORE). `0x8` means on. `devmem` may need `sudo apt install busybox` or `devmem2`.
   - Install the firmware: `sudo install -D -m 0644 rogue_36.56.104.183_v1.fw /lib/firmware/powervr/rogue_36.56.104.183_v1.fw`. This is the libgpu file, sha256 `3974e79f…`.
   - Install the modules, once per board: `sudo mkdir -p /lib/modules/6.6.98-sun60iw2-redroid/extra && sudo cp ~/farm/route-l/*.ko /lib/modules/6.6.98-sun60iw2-redroid/extra/ && sudo depmod -a`. Check `uname -r` first, and `cd ~/farm/route-l && sha256sum -c SHA256SUMS` after the copy.
   - Load the module: `sudo modprobe powervr`. It is built on the build PC against this kernel (`out/route-l/`, not run yet). `modprobe` loads the three helpers first.
   - Check: `dmesg | grep -i -E 'powervr|loaded firmware|FW version|deferring'`, `ls /dev/dri`, and `cat /sys/kernel/debug/dri/*/name` (expect `powervr`).
   - Expect `loaded firmware powervr/rogue_36.56.104.183_v1.fw` and `FW version v1.0 (build 6852738 OS)`, plus a `renderD128` node.
   - Unload before step 5: `sudo rmmod powervr`. Both drivers bind `img,gpu`.
5. **Start the stack.** `./40-board-setup.sh run`. It installs the GPU driver and firmware, loads the image, sets the CPU and memory layout, and starts two instances (`android1` on adb port 5555, `android2` on 5556).
6. **Read the report.** `./50-board-report.sh`. Each line is PASS, WARN or FAIL. The evidence (dmesg, logcat, SurfaceFlinger dump, props) is saved under `~/farm/reports/<time>/`.
7. **Look from the laptop.** `adb connect <ip>:5555` and `adb connect <ip>:5556`, then `adb -s <ip>:5555 shell getprop ro.hardware.egl` and `adb exec-out screencap -p > s1.png`.

## 4. How to read the result

- **PASS** everything in section 2 of the report, `sys.boot_completed=1`, and `ro.hardware.egl=POWERVR_ROGUE`: the GPU is in use.
- **WARN** `PowerVR not selected`: the phones run, but on software rendering. Check `dmesg` for the GPU errors first.
- **FAIL** anything else: send the report folder.

Expected values, for comparison: the DRM device is named `pvr`; SurfaceFlinger shows `PowerVR B-Series BXM-4-64` with `OpenGL ES 3.2 build 24.2@6643903`.

For Route L (step 4b), the DRM name is `powervr` and the log shows `loaded firmware powervr/rogue_36.56.104.183_v1.fw` and `FW version v1.0 (build 6852738 OS)`. If the firmware loads but there is no `renderD128` node, the probe failed after the load: read `dmesg` from that point.

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
| `deferring` in dmesg after `modprobe powervr` | The firmware file is missing or in the wrong path. Check `/lib/firmware/powervr/rogue_36.56.104.183_v1.fw` (sha256 `3974e79f…`). |
| `Unsupported fw info version 2` or `FW info format mismatch` | Wrong firmware file. The Radxa and Android `rgx.fw` copies are info v2 and are not for Route L. |
| `FW built for incorrect GPU ID` | Firmware for another BVNC. Route L needs 36.56.104.183. |
| Board hangs when the GPU starts (Route A) | Likely an SError from a blocked secure-register write. Run Route L first and keep the serial log. |
| PD 5 or PD 6 reads `0x0` after probe | The power domain is off, so the GPU is unpowered. Check the PCK-600 probe in `dmesg`. |
| `Module gpu-sched not found` (or `drm_exec`, `drm_shmem_helper`) after `modprobe powervr` | Step 4b's copy and `sudo depmod -a` were skipped, or the copy went to another kernel's directory. Check `uname -r`. |
| `Unknown symbol` or `version magic` from `modprobe powervr`, or the same in `dmesg` | The module was built for another kernel. `modinfo -F vermagic /lib/modules/$(uname -r)/extra/powervr.ko` must say `6.6.98-sun60iw2-redroid`. |

**Software fallback (GPU not working).** Edit `40-board-setup.sh`: change `androidboot.redroid_gpu_mode=host` to `guest` in the `docker run` lines, then `sudo docker rm -f android1 android2` and `./40-board-setup.sh run`. Everything except the GPU still gets tested.

**Rollback.** `sudo tar -C / -xpf ~/stock-kernel-backup.tar && sudo reboot`. If the board will not boot at all, reflash the stock image (step 1).

## 6. What to send back

- the report folder `~/farm/reports/<time>/`;
- the serial log of the first boot after step 4, and of the first boot after step 5 if there were problems;
- the output of `uname -r` and `sudo dmesg | tail -100` if anything failed.
- For Route L: `dmesg | grep -i -E 'powervr|rogue|FW version|deferring|loaded firmware'`, `cat /sys/kernel/debug/dri/*/name`, and the PD 5 and PD 6 `devmem` readbacks.

## 7. Not in scope for this session

- eMMC: not needed for the SD boot. For eMMC day, the device tree is prepared: `out/zero3w-emmc/sun60i-a733-orangepi-zero3w-emmc.dtb`, with the change in `config/zero3w-emmc-supplies.patch`. VCC comes from DC-DC1 at 3.3 V (`reg_dc1sw2`, the SD card's rail). VCCQ comes from `reg_cldo1` at 1.8 V; confirm it with a meter on the eMMC VCCQ pad before the first boot. The stock Debian device tree already enables the eMMC controller (`sdmmc@4022000`), so an empty socket is probed on every boot with the stock tree too. The eMMC tree only adds the rails. Keep the stock tree for the SD-first boot, and install the eMMC tree once a chip is fitted and VCCQ is confirmed.
- JTAG: not needed now. The schematic routes the JTAG pins to the 40-pin header (PB route), but boot0 and pin muxing are not verified yet.

## 8. Reference images (not for the farm)

- **Radxa A733 Bullseye KDE image** (`radxa-a733_bullseye_kde_r2.output_512.img.xz`, sha256 `1b5604fe…`, kernel 5.15.147-14-a733). It ships a prebuilt Linux GPU stack: the DKMS package `img-bxm-dkms` 0.1.0-2, a built `pvrsrvkm.ko.xz` for its kernel (DDK 24.2@6603887, Linux WS build), the IMG user-space libraries (24.2.6603887), and firmware 36.56.104.183. Its `rgx.sh` is byte-identical to the kit's; its `rgx.fw` is not (`43eb5d05…` against the kit's Android copy `11e08779…`). Its EGL is Mesa's. Its sunxi layer defines the DRM_CTRL register, but I found no write to it and no SMC secure-release call, so it doesn't settle the secure-reset question. Use it to compare the Linux driver and its start sequence. Do not use it as a base: the kernel is 5.15.
- **Orange Pi Android 13 pack** (`OrangePiZero3W_A733_Android13_lcd_v1.0`): Android-flavour `pvrsrvkm`, DDK 24.2@6643903 strings, firmware 36.56.104.183, kernel 5.15.119, `buildvariant=userdebug`. Use it for the Android blobs and the device tree. Do not flash it to the farm.
- **Allwinner libgpu** (`tina5.0_aiot/product/linux/external/libgpu`, commit `144487e8`): the open-source firmware `powervr/rogue_36.56.104.183_v1.fw` for Route L, and the DDK 6603887 userspace libraries (for the DDK kernel driver, not Route L). Mirror it with the rest.
- Mirror the Radxa apt repo (`radxa-repo.github.io/a733-bullseye`) and keep the Orange Pi pack, before the links disappear.
