# A733 board day: the first session

> Written for: the person bringing up the first Orange Pi Zero 3W (6 GB) with the redroid + PowerVR farm.
> Prepared in software on 2026-10-28. Nothing here has run on hardware yet.

## 1. What is ready, and what the board must decide

Ready (built or checked without a board):

- Kernel `6.6.98-sun60iw2-redroid`: binder, PSI, zram, docker options, USB Ethernet (`r8152` module). Packages in `out/deploy/debs/`.
- GPU driver `pvrsrvkm` (Android flavour, DDK 24.2@6643903) and the matching firmware `rgx.fw` / `rgx.sh` (36.56.104.183). The driver and blobs match (script 25 PASS).
- redroid 13 with the PowerVR overlay: `redroid-pvr-13-arm64.tar`, 668 MB, built on the stock `redroid/redroid:13.0.0_64only-240527` arm64 image. Its entrypoint is the stock one. **Never booted.**
- Scripts: `40-board-setup.sh` (kernel, run), `45-usb-net.sh` (USB Ethernet), `50-board-report.sh` (PASS / WARN / FAIL report).

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

1. **Flash the OS.** Write Orange Pi Debian bookworm "current" (6.6) to the SD card from the Orange Pi download page. Power on with the serial adapter attached and log in as the default `orangepi` user.
2. **Note the stock kernel.** `uname -r` shows the stock 6.6 kernel. This is the rollback target.
3. **Copy the kit** (from the build PC, or from the laptop copy). Replace `<ip>` with the board's address:
   ```bash
   rsync -a out/deploy out/redroid-pvr-13-arm64.tar scripts/40-board-setup.sh scripts/45-usb-net.sh scripts/50-board-report.sh orangepi@<ip>:~/farm/
   ```
4. **Install the kernel, then reboot.** `cd ~/farm && ./40-board-setup.sh kernel && sudo reboot`. The package replaces `/boot/uImage`. Watch the serial log: U-Boot must load the uImage and the Zero 3W device tree, and the kernel banner must say `6.6.98-sun60iw2-redroid`. Then `uname -r`.
5. **Start the stack.** `./40-board-setup.sh run`. It installs the GPU driver and firmware, loads the image, sets the CPU and memory layout, and starts two instances (`android1` on adb port 5555, `android2` on 5556).
6. **Read the report.** `./50-board-report.sh`. Each line is PASS, WARN or FAIL. The evidence (dmesg, logcat, SurfaceFlinger dump, props) is saved under `~/farm/reports/<time>/`.
7. **Look from the laptop.** `adb connect <ip>:5555` and `adb connect <ip>:5556`, then `adb -s <ip>:5555 shell getprop ro.hardware.egl` and `adb exec-out screencap -p > s1.png`.

## 4. How to read the result

- **PASS** everything in section 2 of the report, `sys.boot_completed=1`, and `ro.hardware.egl=POWERVR_ROGUE`: the GPU is in use.
- **WARN** `PowerVR not selected`: the phones run, but on software rendering. Check `dmesg` for the GPU errors first.
- **FAIL** anything else: send the report folder.

Expected values, for comparison: the DRM device is named `pvr`; SurfaceFlinger shows `PowerVR B-Series BXM-4-64` with `OpenGL ES 3.2 build 24.2@6643903`.

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

**Software fallback (GPU not working).** Edit `40-board-setup.sh`: change `androidboot.redroid_gpu_mode=host` to `guest` in the `docker run` lines, then `sudo docker rm -f android1 android2` and `./40-board-setup.sh run`. Everything except the GPU still gets tested.

**Rollback.** `sudo apt install --reinstall linux-image-current-sun60iw2 && sudo reboot`. If the board will not boot at all, reflash the stock image (step 1).

## 6. What to send back

- the report folder `~/farm/reports/<time>/`;
- the serial log of the first boot after step 4, and of the first boot after step 5 if there were problems;
- the output of `uname -r` and `sudo dmesg | tail -100` if anything failed.

## 7. Not in scope for this session

- eMMC: not needed for the SD boot. For eMMC day, the device tree is prepared: `out/zero3w-emmc/sun60i-a733-orangepi-zero3w-emmc.dtb`, with the change in `config/zero3w-emmc-supplies.patch`. VCC comes from DC-DC1 at 3.3 V (`reg_dc1sw2`, the SD card's rail). VCCQ comes from `reg_cldo1` at 1.8 V; confirm it with a meter on the eMMC VCCQ pad before the first boot. Do not install that DTB while the socket is empty; the MMC core would retry the missing chip and may slow the boot.
- JTAG: not needed now. The schematic routes the JTAG pins to the 40-pin header (PB route), but boot0 and pin muxing are not verified yet.
