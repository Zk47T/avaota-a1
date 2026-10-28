# A733 Android farm: PowerVR GPU inside redroid

Goal: run 2 Android instances on each Allwinner A733 board (Orange Pi Zero 3W / Zero 4). Each instance is a redroid container, and the PowerVR BXM-4-64 GPU does the rendering.

Pilot board: **Orange Pi Zero 3W, 6 GB**, with a USB-C GbE dongle (section 8). The scripts work unchanged on the Zero 4.

Status on 2026-10-28. Everything that can be built or checked without an A733 board has been done.

- **On this PC:** the kernel and GPU driver were built, and the checks were static: reading binaries and image files.
- **Not built or run on this PC:** redroid (there's no Docker here).
- **Still to do:**
  - Run a redroid boot test on your other PC (section 7). Do this before buying.
  - Then verify on one pilot board (sections 9–10).

| What | State | Evidence |
|---|---|---|
| Host kernel 6.6.98 (Orange Pi tree) with binder/binderfs/PSI/SW_SYNC and Docker extras | **built** | `out/deploy/debs/linux-image-current-sun60iw2-redroid_1.0-redroid_arm64.deb`. Docker's `check-config.sh` reports only optional SCTP/ZFS missing. |
| GPU kernel driver, **Android flavour**, DDK 24.2@6643903 | **built** | `out/deploy/lib/modules/pvrsrvkm-android.ko`: 0 warnings, 0 unresolved symbols, vermagic `6.6.98-sun60iw2-redroid` |
| Bring-up fix ported from Orange Pi's Linux driver (GPU secure reset) | **patched + built** | `config/pvrsrvkm-android-sunxi-secure-config.patch`, confirmed in the disassembly |
| Kernel driver ↔ Android blobs connect handshake | **PASS (static)** | `scripts/25`: DDK 24.2@6643903 on both sides, build options `0x00020010` on both |
| Blobs link inside redroid 13 arm64 (Android linker-namespace rules) | **PASS (static)** | `scripts/26`: 9 entry points, 2,419 imports, 0 problems. The negative test catches both failure kinds. |
| redroid fit: binderfs, composer, Vulkan features, CMA, `/dev/pvr_sync`, firmware name | **checked** | section 5 |
| Overlay image context (stock redroid + blobs) | **ready** | `out/redroid-pvr/`: COPY-only Dockerfile |
| AOSP vendor tree for a **source-built** redroid | **ready** | `out/aosp/vendor/powervr-a733/`: 18 Soong prebuilt modules, plus a `vendor/redroid` patch |
| Image boots on a non-PowerVR redroid host, blobs load in real Android | **your other PC** | `scripts/35`, section 7 |
| `insmod`, GPU firmware boot, SurfaceFlinger on PowerVR, 2 instances | **pilot board** | `scripts/40`, sections 9–11 |

---

## 1. Is there a working PowerVR stack for A733 to build on? Yes, three

| Stack | What it is | Where | Role here |
|---|---|---|---|
| **Vendor Android 13** | Allwinner's Android userspace: EGL, GLES 3.2, Vulkan, gralloc 4, OpenCL, **DDK 24.2@6643903**. Also the **kernel driver source of the same build** (MIT/GPL). | `gitlab.com/aw_android13/gpu/gpu` and `.../lichee/bsp` → `modules/gpu/img-bxm/android/rogue_km`, branch `a733-radxa-v1.0` (Radxa's public A733 Android 13 SDK) | **Plan A.** Both halves come from one build. |
| Vendor Linux | Allwinner AIoT SDK v1.5.0 / Orange Pi Debian: DDK 24.2@6603887, Wayland/X11, GLES, Vulkan 1.3, OpenCL | `gitlab.com/tina5.0_aiot/...` and Orange Pi's kernel `bsp/` | What stock Debian loads. Wrong flavour for Android, but its newer platform glue gave us one fix (section 4). |
| Open source | `apercel` (Oct 2026): the upstream `drm/imagination` driver built out of tree, plus a patch to Mesa 26.1.8 for BVNC 36.56.104.183. Vulkan + Zink, tested on an Orange Pi 4 Pro (A733). Linux 7.3 lists BXM-4-64 MC1 (TH1520) as supported; Mesa BXM-4-64 isn't conformant yet. | github.com/TumRedSun/apercel | Plan B (section 13), and an upstream opportunity. |

Imagination's DDK has a mode for Android running in a container on ChromeOS (ARC++): one host driver serves an Android userspace in a container (`SUPPORT_ARC_PLATFORM`). redroid does the same thing.

## 2. How it fits together

```
 Orange Pi Debian (host)                       redroid container x2 (Android 13, 64-bit)
 ───────────────────────                       ────────────────────────────────────────
 kernel 6.6.98-sun60iw2-redroid                /vendor/lib64/egl/lib*_POWERVR_ROGUE.so   GLES 3.2
   + binder, binderfs, PSI, SW_SYNC            /vendor/lib64/hw/vulkan.powervr.so        Vulkan
   + pvrsrvkm.ko (ANDROID flavour,             /vendor/lib64/hw/gralloc.powervr.so       buffers
     DDK 24.2@6643903, + secure-reset fix)     mapper@4.0-impl + allocator@4.0-service   (gated)
   + /lib/firmware/rgx.fw.36.56.104.183        libsrv_um.so (DDK 24.2@6643903)
     (Android copy, loaded by the HOST)        gpu_config.sh: sees "pvr" DRM node -> IMG blobs
 /dev/dri/card*, renderD*, /dev/pvr_sync ───── shared by both containers (--privileged)
 binderfs ──────────────────────────────────── each container mounts its own instance
```

1. **One kernel driver serves every container, so all their userspaces must match it.**
   - `srvcore.c` hard-fails if the DDK major.minor differs.
   - A different build number only logs a warning.
   - Some build-option bits are "strict" and also hard-fail.
   - So we build the Android flavour at the blobs' exact build. Debian's Linux-flavour `pvrsrvkm` isn't in our kernel package.
2. The firmware is loaded by the **host** (`request_firmware("rgx.fw.36.56.104.183")`), so it must be the Android copy.

## 3. Folder layout

```
3.a733-android-farm/                     (tracked in git: README, config/, scripts/)
├── config/
│   ├── linux-sun60iw2-current-a733.config         Orange Pi's kernel config (orangepi-build a95129bf3)
│   ├── redroid-host.fragment                      options added on top of it
│   ├── pvrsrvkm-android-sunxi-secure-config.patch GPU secure-reset fix (section 4)
│   ├── vendor_redroid-gpu_config-pvr.patch        PowerVR case for source-built redroid
│   ├── redroid-13-gpu_config.orig.sh              redroid's own GPU script (overlay fallback)
│   └── headers-debian-byteshift.patch             needed by Orange Pi's builddeb
├── scripts/
│   ├── env.sh                           toolchain + paths
│   ├── 00-fetch-sources.sh              recreate src/ at pinned commits (groups: kernel gpu ref)
│   ├── 10-build-host-kernel.sh          kernel + fragment
│   ├── 15-package-kernel-deb.sh         -> linux-image/dtb/headers .deb
│   ├── 20-build-pvrsrvkm-android.sh     Android-flavour GPU driver (+ patch)
│   ├── 25-check-km-um-match.sh          static connect-handshake check
│   ├── 26-check-blobs-vs-redroid.sh     static link check vs the real redroid image
│   ├── redroid_link_check.py            (used by 26)
│   ├── 30-make-redroid-pvr-context.sh   overlay image context (stock redroid + blobs)
│   ├── 31-make-aosp-vendor-tree.sh      vendor/powervr-a733 for SOURCE-built redroid
│   ├── 35-test-on-redroid-host.sh       RUN ON YOUR OTHER REDROID PC
│   ├── 40-board-setup.sh                RUN ON THE A733 BOARD
│   └── 45-usb-net.sh                    board, optional: USB GbE dongle or USB NCM gadget
├── src/   (git-ignored; 00-fetch-sources.sh)
└── out/   (git-ignored; contains vendor blobs, do not publish)
```

## 4. Bring-up risk found and fixed: platform glue differences

The Android driver (Radxa SDK, Aug 2025) and Orange Pi's Linux driver (Allwinner v1.5.0, 2026) share the same core. Their A733 glue (`services/system/rogue/rgx_sunxi`) differs:

| Difference | Effect on Orange Pi boards | Action |
|---|---|---|
| The Linux driver calls `sunxi_secure_config()` before **every** GPU start (`RGXDoStart` → `pfnTDSystemSecureConfig`). It writes `0x2` to `0x0a0000b0` (releases the GPU "DRM"/secure reset in the SMC) and `0` to `0x01880014` (`GPU_GLB.DRM_CTRL`). The older Android core has no such hook. | Without it, the GPU firmware may not boot on Orange Pi's boot firmware. | **Ported**: runs in `sunxiPrePowerState` after clocks and power are on, before `RGXStart`. |
| GPU voltages: Linux picks `opp-microvolt-vfXXXX` by eFuse bin; Android reads plain `opp-microvolt`. | Orange Pi's DT has both. Plain = highest bin: 400/600 MHz 0.80 V, 800 MHz 0.84 V, 1008 MHz 0.96 V. | Nothing to do (safe, slightly conservative). |

## 5. redroid fit, checked against the real `redroid/redroid:13.0.0_64only` arm64 image

| Item | Finding |
|---|---|
| Linker namespaces | EGL/GLES/Vulkan/mapper/gralloc run in the `sphal` namespace. Their deps are VNDK-SP (libion, libdmabufheap, libgralloctypes, libhardware, mapper@4.0) or LLNDK (libsync, libnativewindow, liblog). `scripts/26`: 0 problems. |
| Binder | redroid 13 mounts **its own binderfs per container** and creates binder/hwbinder/vndbinder itself. So the host needs `ANDROID_BINDERFS=y` and `ANDROID_BINDER_DEVICES=""` (our fragment). |
| Composer | `hwcomposer.redroid` only runs vsync. With `use_redroid_stream=1` it passes buffer fds over `/ipc/hwcomposer.sock`. It never maps buffers through gralloc. SurfaceFlinger composes with GLES, which runs on the PowerVR. |
| Vulkan | The image already declares `vulkan.level-1`, `version-1_1` and `compute-0`. The blob exports `HMI` (hwvulkan). |
| Fences | `EGL_ANDROID_native_fence_sync` is present. The driver is built with `SUPPORT_NATIVE_FENCE_SYNC` and registers `/dev/pvr_sync`. |
| dma-buf heaps | `system` + `reserved` (default CMA, 16 MB). Allwinner's own Android boots with `cma=8M`; the display uses the SMMU. Fine. |
| GPU selection | Our `gpu_config.sh` runs at `early-boot`, before the HALs. On a `pvr` DRM node it sets `ro.hardware.{egl,vulkan,gralloc}` and starts the IMG allocator; otherwise it hands over to redroid's script. |
| IMG allocator | It's gated (`disabled`, started by `vendor.redroid.pvr=1`). Ungated, it crash-loops on non-PowerVR hosts, and its `onrestart restart surfaceflinger` blocks boot. |
| Docker kernel needs | moby `check-config.sh`: all "generally necessary" options are present, after adding IPv6 masquerade, `NFT_FIB_*` and VLAN filtering. redroid's documented mandatory features (binderfs, memfd) are present. |
| Unknown until section 7 | On a **non**-PowerVR host the IMG mapper 4.0 is still declared in VINTF. Does SurfaceFlinger skip it cleanly? |

## 6. PC side (this PC: done)

```bash
./scripts/00-fetch-sources.sh            # only on a fresh checkout (~2.5 GB)
./scripts/10-build-host-kernel.sh        # ~2 min, 12 cores
./scripts/15-package-kernel-deb.sh       # ~2 min
./scripts/20-build-pvrsrvkm-android.sh   # ~1 min
./scripts/25-check-km-um-match.sh        # RESULT: PASS
./scripts/26-check-blobs-vs-redroid.sh   # 0 with problems
./scripts/30-make-redroid-pvr-context.sh # overlay route
./scripts/31-make-aosp-vendor-tree.sh    # source-build route
```

Toolchain:
- On this PC: Yocto GCC 13.3, wrapped by `env.sh`.
- Elsewhere: `apt install gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu flex bison bc libssl-dev libelf-dev dwarves u-boot-tools python3-pyelftools`.

| Kernel option (`config/redroid-host.fragment`) | Why |
|---|---|
| `ANDROID_BINDER_IPC=y`, `ANDROID_BINDERFS=y`, `ANDROID_BINDER_DEVICES=""` | Android IPC. Off in Orange Pi's config, and can't be a module in 6.6. |
| `PSI=y` | lmkd needs `/proc/pressure/*` |
| `SW_SYNC=y` | explicit fences |
| `VETH=y`, `BRIDGE_NETFILTER=y`, `BRIDGE_VLAN_FILTERING=y` | Docker networking |
| `IP6_NF_TARGET_MASQUERADE=m`, `NFT_FIB_IPV4/IPV6/INET=m` | Docker ≥27 ip6tables default, and the ≥28 nftables backend |
| `UCLAMP_TASK(_GROUP)=y`, `ENERGY_MODEL=y`, `LRU_GEN(_ENABLED)=y`, `CRYPTO_LZ4=y` | foreground boost onto the A76, energy-aware scheduling, better reclaim and zram for 4 GB boards (section 8.1) |

## 7. Before buying: verify on your other redroid PC

What this proves, and what it can't:

- **Proves:**
  - The image is sound.
  - The PowerVR userspace loads in a real Android 13.
  - The fallback path is safe.
- **Can't prove:** the GPU itself. Nothing without an A733 can.
  - Emulation won't work: there's no PowerVR emulator, and a NO_HARDWARE driver build changes a strict option bit, so the blobs would refuse it.
  - The cheapest remaining test is **one pilot board** (6 GB Zero 3W, ~$60). Buy the cluster only after it passes section 10.

**Route A: overlay on stock redroid (fast).** Run this on an **arm64** redroid host, e.g. your Orange Pi 5 Plus:

```bash
git clone <this repo> && cd avaota-a1/3.a733-android-farm
./scripts/00-fetch-sources.sh gpu        # ~110 MB, no compiler needed
./scripts/30-make-redroid-pvr-context.sh
./scripts/35-test-on-redroid-host.sh     # needs docker + adb
```

It builds `redroid-pvr:13`, boots it with no PowerVR GPU, runs `ldd` on every blob inside Android, and prints the props plus which mapper SurfaceFlinger chose.

**Pass criteria:**

1. `boot_completed=1`.
2. Every `ldd` line says `ok`.
3. `vendor.redroid.pvr` is empty and `init.svc.vendor.gralloc-4-0` isn't `running`.
4. The UI works through scrcpy.

If (4) fails because Gralloc4/PowerVR got picked, the image is PowerVR-only. That's fine for the farm.

On an x86_64 PC, `35` only cross-builds `out/redroid-pvr-13-arm64.tar` to carry to the board.

**Route B: source-built redroid (you build redroid anyway).**

1. Generate the vendor tree:
   ```bash
   ./scripts/00-fetch-sources.sh gpu && ./scripts/31-make-aosp-vendor-tree.sh
   ```
2. Set up the redroid 13 tree (`remote-android/platform_manifests`, branch `redroid-13.0.0_r74`, or the redroid-patches flow):
   ```bash
   cp -r out/aosp/vendor/powervr-a733  <redroid>/vendor/
   echo '$(call inherit-product, vendor/powervr-a733/powervr-a733.mk)' >> <redroid>/device/redroid/redroid_arm64_only/device.mk
   (cd <redroid>/vendor/redroid && patch -p1 < ../powervr-a733/vendor_redroid-gpu_config-pvr.patch)
   ```
3. Build inside the redroid builder container:
   ```bash
   lunch redroid_arm64_only-userdebug && m
   ```
4. Make the image with redroid-doc's mount + tar + `docker import` step, adding `--platform linux/arm64` on an x86 build PC.
5. `docker save` it, load it on the arm64 host, then run `IMAGE=<tag> ./scripts/35-test-on-redroid-host.sh`.

Why route B is worth it:
- The blobs become real Soong modules: `check_elf_files: false`, unique module names with `stem`, and `init_rc`/`vintf_fragments` attached.
- No BUILD_BROKEN flags are needed.
- If the HAL mix ever needs changes (e.g. dropping redroid's allocator 2.0), it's one line in the product makefile.

## 8. Networking and board choice: Ethernet or USB? Zero 3W or Zero 4?

**The facts:**
- **USB-C ports.** Both boards have the same two:
  - a **5 V/3 A power port**, with USB 2.0 OTG data (Allwinner UDC, also FEL);
  - a **USB 3.1 OTG port** with DP alt mode. It's DWC3 `dr_mode="otg"`, and the HUSB311 Type-C controller switches the role by cable (`data-role = "dual"`).
- **USB 3 and PCIe don't share a lane.** USB 3 uses `combo0_usb`, PCIe uses `combo1_pcie`.
- **Ethernet and prices.** The Zero 4 adds RJ45 GbE (YT8531C) and costs $63 at 6 GB; the Zero 3W costs $60 at 6 GB. The Zero 4 *does* come in 6 GB.
- **Cooling.** The Zero 3W kit ships an **active heatsink** (fan, 4 screws, thermal pads). A review measured 57→63 °C during a one-minute all-core stress, no throttling, ~7 W peak.
- **Kernel support** (already in our kernel): `USB_RTL8152=m`, `USB_NET_AX88179_178A=y`, `USB_DWC3_DUAL_ROLE=y`, `USB_CONFIGFS_NCM=y`, `TYPEC_FUSB302=y`.

**Is USB OTG enough bandwidth? Yes, easily.**

| Need per board (2 instances) | Rough rate |
|---|---|
| scrcpy 720p30 H.264 per instance | 2–8 Mbit/s |
| app traffic per instance (feeds, video) | 5–20 Mbit/s |
| APK install / data sync bursts | occasional, hundreds of MB |
| **Total typical** | **< 50 Mbit/s** |
| USB 2.0 NCM gadget (practical) | ~150–300 Mbit/s |
| USB 3 NCM gadget / USB GbE dongle | ~1 Gbit/s |

**Why Ethernet still wins for the topology:**

| | RJ45 (Zero 4) or **USB-C GbE dongle (Zero 3W)** | USB NCM gadget to a host PC |
|---|---|---|
| Single point of failure | a cheap switch | the host PC, its USB stack and hubs |
| Power | separate PSU per board | still a separate PSU: the gadget port isn't the power port, and one USB 2.0 data+power cable at 7–10 W per board through a hub is unrealistic |
| Scaling | switch ports | hub ports and xHCI endpoint limits; USB resets drop links |
| Setup | DHCP, done | host bridge/NAT for each `usbN` netdev |
| Distance | 100 m | 1–3 m |

**Recommendation:**
- **Zero 3W + USB-C GbE dongle (RTL8153, ~$5–8)** on its USB 3 OTG port. That gives the Zero 4's network design plus the 3W's included active cooler, its narrow 65×32 mm board (stacks densely), and the rework advantages from main README 3.10.
- Total cost is about the same as a Zero 4 with an add-on fan.
- The USB NCM gadget is a valid alternative if every board plugs into one controller PC anyway.
- `scripts/45-usb-net.sh dongle|gadget|status` sets up either.

### 8.1 Sizing: CPU, GPU, RAM, storage for 2 × TikTok/Instagram

**CPU layout** (`40-board-setup.sh run`). The A733 DT gives `capacity-dmips-mhz` A55 = 430, A76 = 1024. At 1.8 vs 2.0 GHz, one A55 ≈ 0.38 A76.

| CPUs | Used by |
|---|---|
| cpu0 (A55) | host: systemd slices `AllowedCPUs=0`, all IRQs, dockerd, zram compression |
| cpu1, 2 (A55) + **cpu6 (A76)** | instance 1 |
| cpu3, 4 (A55) + **cpu7 (A76)** | instance 2 |
| cpu5 (A55) | shared spare for both instances |

- Don't restrict Android to the A76 only. An instance runs about 100 threads (system_server, SurfaceFlinger, the app, codecs), and one big core alone would starve.
- The kernel scheduler (capacity-aware, `schedutil`) already moves the heavy app threads to the instance's A76.
- The fragment adds `UCLAMP_TASK(_GROUP)`, so Android's foreground boost works; `ENERGY_MODEL` (EAS, using the DT power coefficients); and `LRU_GEN` (MGLRU).

**GPU for TikTok/Instagram: not the bottleneck.**
- BXM-4-64 ≈ 4 pixels/clock × ~1 GHz ≈ 4 Gpixel/s.
- Two 720×1280 @ 30 fps screens are 55 Mpixel/s. Even at 10× overdraw (UI layers, video texture, composition) that's ~14% of the GPU.
- The real cost is **video decoding**: redroid uses software codecs on the CPU, and some apps ship their own software decoders anyway.
  - 720p H.264 ≈ 0.3–0.5 of an A76; 720p HEVC more.
  - That's why each instance gets a dedicated A76.
- Next improvement: wire the A733 video engine (`cedar-ve`, already in the kernel) into the containers through Allwinner's Android Codec2 HAL, the same way the GPU was done. It decodes 4K60 HEVC, so 2 × 720p is trivial for it.

**RAM per instance** (redroid 13, no GMS; rough):

| | Typical |
|---|---|
| Android system (system_server, SF, HALs) | 0.7–0.9 GB |
| TikTok or Instagram in foreground | 0.4–0.7 GB |
| GMS / microG, if needed | +0.2–0.4 GB |
| **Instance total** | **1.3–1.9 GB** |

| Board | Host | 2 instances | Verdict |
|---|---|---|---|
| **6 GB** (Zero 3W $60, **Zero 4 $63**) | ~0.4 GB | 2 × 2.2 GB limit + 2 GB zram | comfortable |
| 4 GB (Zero 4 $52) | ~0.4 GB | 2 × 1.6 GB limit + **3 GB zram** | works with **one app per instance**; background apps get killed, some stutter when switching |

- Use **zram, not swap on eMMC**. eMMC swap has high latency (jank, ANRs) and wears out a chip you hand-soldered.
- zstd zram compresses Android memory about 2.5–3×, and the spare A55s pay the compression cost.
- For +$11 the 6 GB board removes the problem. Pick 4 GB only if the budget forces it.

**Storage per instance:**
- The Android system lives in the Docker image, which is shared and read-only (~2 GB once per board).
- Per-instance `/data` holds TikTok (~0.5 GB installed) + Instagram (~0.4 GB) + caches. TikTok's video cache can grow to 1–2 GB, so **4 GB per instance is enough** if you trim caches now and then (`adb shell pm trim-caches 1G`).
- `SHARED_DATA=1 ./40-board-setup.sh run` uses redroid's overlay `/data`: apps are installed once in `data-base`, and each instance keeps only its diff (account + cache, ~1–2 GB).
- 16 GB eMMC budget: host ~2.5 GB + image ~2 GB + 2 × 4 GB data ≈ 12.5 GB. That fits; 32 GB gives room.

**Zero 4 (6 GB) vs Zero 3W (6 GB) for this farm:**
- **Zero 4:** RJ45 GbE onboard, so one power cable + one Ethernet cable and no dongle or hub. Add a heatsink and a 30 mm fan on its fan header.
- **Zero 3W:** active cooler in the kit, but it needs a USB-C GbE dongle.
- Same SoC, same images, same kernel, about the same total cost.
- On paper the **Zero 4** is simpler to cable and has fewer USB failure points.
- **Decision (2026-10-28): pilot on a Zero 3W 6 GB** + USB-C GbE dongle (RTL8153), because the local shop has no Zero 4 6 GB.
  - Same SoC, kernel, images and scripts.
  - Run `45-usb-net.sh dongle` and keep the kit's active cooler fitted.
  - Revisit the Zero 4 6 GB for boards 2 and 3 if it becomes available.
  - The same Zero 3W is also the DDR-study and upstream board (main README 3.11).

## 9. On the A733 board

1. Flash Orange Pi Debian **bookworm "current" (6.6)**.
2. `rsync -a out/deploy out/redroid-pvr scripts/40-board-setup.sh scripts/45-usb-net.sh orangepi@<ip>:~/farm/`, plus `redroid-pvr-13-arm64.tar` if you built one.
3. On the board:
   ```bash
   ./40-board-setup.sh kernel && sudo reboot    # installs next to the stock kernel
   ./40-board-setup.sh run                      # GPU driver + firmware, image, 2 pinned instances
   ```
   - Rollback: `sudo apt install --reinstall linux-image-current-sun60iw2 && sudo reboot`.
   - Instances: CPUs `0,1,2,6` / `3,4,5,7`, `--memory=1536m`, 720×1280 at 30 fps, adb 5555/5556.

## 10. Board checklist

| Check | Command | Expected |
|---|---|---|
| Kernel | `uname -r` | `6.6.98-sun60iw2-redroid` |
| Binder | `grep binder /proc/filesystems` | `binder` |
| Driver | `dmesg \| grep -i -E "pvr\|sunxi bxm"` | `[sunxi bxm]... end!`, no `failed` |
| DRM node | `sudo cat /sys/kernel/debug/dri/*/name` | one line starts with `pvr` |
| Firmware boots | dmesg after the first container starts | no "failed to load", no boot timeout |
| Container picked IMG | `adb -s <ip>:5555 shell getprop ro.hardware.egl` | `POWERVR_ROGUE` |
| GLES on GPU | `adb shell dumpsys SurfaceFlinger \| grep -A1 GLES` | `Imagination Technologies, PowerVR B-Series BXM-4-64…, OpenGL ES 3.2 build 24.2@6643903` |
| Handshake | host `dmesg \| grep -i -E "COMPAT_TEST\|Mismatch"` | no `(FAIL)` |
| GPU health | host `sudo cat /sys/kernel/debug/pvr/status` | driver status OK |
| GPU memory per app | host `sudo cat /sys/kernel/debug/pvr/proc_stats/live_pids_stats/*` (or `gpu_mem_area`) | numbers to size the 1.5 GB limit |
| 2 instances | `docker stats`, 30 min of use | each ≤1.5 GB, no throttling (`/sys/class/thermal`) |

## 11. If it breaks, and where JTAG helps

| Symptom | First tool | Fix |
|---|---|---|
| `insmod: Invalid module format` | `uname -r` | rebuild step 20 against the running kernel |
| GPU firmware boot timeout / GPU hang at first open | `pvr/debug_dump`, `pvr/firmware_trace`; then **JTAG** (below) | check the secure-reset registers (section 4) |
| `(FAIL) ... build options` | `scripts/25` | keep blobs and driver at the same build |
| SurfaceFlinger restarts, gralloc/mapper errors | `logcat`, `lshal \| grep graphics` | if allocator 2.0 fights 4.0, add an empty `android.hardware.graphics.allocator@2.0-service.rc` to the overlay, or drop it in route B |
| apps render, scrcpy/VNC black | `adb exec-out screencap -p` | TFBC/FBC switch in `/vendor/etc/powervr.ini`, or route B |
| 2nd instance slow / OOM | `pvr/proc_stats`, `docker stats` | 6 GB board; ZRAM; 540p |
| board freezes hard, no serial output | **JTAG** | see below |

**JTAG for this project.** Use the same CH347F + SD-sniffer wiring as on the T113 (main README 3.9). Two differences on the A733:
- the pin-mux register is `PF_CFG0` at `0x02000300`, value `0x0f3f3f33`;
- the CMD/DAT0 GPIO numbers are swapped compared with the T527, but the sniffer wiring is the same.

| Situation | JTAG value | What exactly |
|---|---|---|
| GPU firmware won't boot / GPU bus hang | **high** | With the cores halted, or live through a MEM-AP, read `0x0a0000b0`, `0x01880014` and the GPU registers at `0x01800000`. Compare stock Debian (Linux driver works) with ours. Shows whether the secure reset is released and whether the CPU is stuck in a GPU register access. |
| Hard lockup / SError (e.g. a register write the secure world blocks) | **high** | Halt the A55/A76 cores and read PC/ESR/FAR when the kernel can't print anything. |
| eMMC / UFS you soldered won't boot | **high** | Halt in boot0/SPL to see where SMHC/UFS init stops; FEL is the other half of this. |
| Custom kernel silent at boot | medium | Halt and read the PC, or `__log_buf` from memory. Usually serial `earlycon` is enough. |
| GPU firmware internals | **none** | The firmware runs on the GPU's own **MIPS** core (`RGX_FEATURE_MIPS`), which isn't on the CPU JTAG chain. Use `pvr/firmware_trace`, `debug_dump`, `firmware_mappings`, `pvrdebug`, and GPU ftrace (on by default). |
| redroid / Android / gralloc / performance | **none** | `adb logcat`, `dmesg`, `perf`, the `pvr` debugfs |

Practical limit: SD-sniffer JTAG uses the **microSD pins**, so it only works while the board boots from somewhere else. That's another reason to solder eMMC/UFS (Orange Pi ships `boot0_ufs_orangepizero3w.fex`). Until then, use FEL (`xfel write32 0x02000300 0x0f3f3f33`) or the PB route `[?]`. The OpenOCD target is a CoreSight-600 DAP; try `-adiv6` if ADIv5 fails.

## 12. Build quirks fixed on the way

1. Yocto keeps gcc and binutils apart, so `env.sh` uses a `-B` gcc wrapper (host gcc untouched).
2. `cedar-ve` breaks `O=` builds, so the kernel is built in-tree like orangepi-build.
3. The DDK uses `TOP`, so our scripts use `FARM`.
4. The DDK only knows `aarch64-none-linux-gnu`, so the build copies that profile for `aarch64-linux-gnu`.
5. Allwinner hard-coded `$(KERNELDIR)/source/Makefile`, and `grep` **hangs** on a plain tree. The build restores Imagination's fallback.
6. The Android flavour forces `override KERNEL_CC := clang`; the build changes it to `?=` and uses GCC.
7. Orange Pi's `builddeb` reads a hard-coded patch path and names packages from `$BRANCH`. The build rewrites the path (move-proof) and sets `BRANCH=current`.

## 13. Fallbacks

- **Plan B, open stack.** `apercel` / upstream `drm/imagination` on the host; Mesa `imagination` Vulkan plus ANGLE (already in redroid 13) in the container. No DDK matching, upstreamable. Risks: non-conformant Vulkan 1.2, and gralloc needs minigbm/gbm support for `powervr`.
- **Plan C, software.** redroid `guest` mode (ANGLE on SwiftShader). Only for light apps.

## 14. Source revisions

| Repo | Branch | Commit |
|---|---|---|
| orangepi-xunlong/linux-orangepi | orange-pi-6.6-sun60iw2 | 2ac08e8c7 (2026-09-17) |
| orangepi-xunlong/orangepi-build | next | a95129bf3 (2026-09-28) |
| gitlab aw_android13/lichee/bsp | a733-radxa-v1.0 | 1775e037b (2025-08-08) |
| gitlab aw_android13/gpu/gpu | a733-radxa-v1.0 | c923a3879 (2025-07-18) |
| gitlab tina5.0_aiot/lichee/bsp | product-aiot-stable | a5fe19707 (2026-07-15, v1.5.0) |
| gitlab tina5.0_aiot/product/linux/external/libgpu | product-aiot-stable | 144487e87 |
| gitlab tina5.0_aiot/lichee/device/config/a733 | product-aiot-stable | fe97b5228 |
| radxa/allwinner-android-manifests | Android13_A733_v1.0 | ed4ee7b17 |
| remote-android/device_redroid | redroid-13.0.0 | 736f66d85 |
| remote-android/vendor_redroid | master | 1686c1825 (2025-06-24), base of the gpu_config patch |
| redroid image | `redroid/redroid:13.0.0_64only-240527` (= `-latest`) | arm64 layer sha256:7ae0e911… |

Licences:
- The GPU kernel driver is dual MIT/GPL.
- The userspace blobs are Imagination/Allwinner binaries from public SDK repos: fine for your own farm, but don't publish images that contain them (`out/` is git-ignored).

## 15. References

- Radxa A733 Android build: https://docs.radxa.com/en/cubie/a7z/other-system/android/low-level-dev/build-system
- apercel: https://github.com/TumRedSun/apercel
- Orange Pi Zero 3W: https://www.cnx-software.com/2026/04/15/orange-pi-zero-3w-an-allwinner-a733-sbc-in-raspberry-pi-zero-form-factor/ and review https://www.androidpimp.com/embedded/orange-pi-zero-3w-review/4/
- Orange Pi Zero 4: https://www.cnx-software.com/2026/08/31/orange-pi-zero-4-allwinner-a733-sbc-offers-hdmi-usb-c-dp-gbe-wifi-6-pcie-ffc-connector/
- Mesa PowerVR: https://docs.mesa3d.org/drivers/powervr.html
- redroid: https://github.com/remote-android/redroid-doc (build: `android-builder-docker/`), https://github.com/remote-android/vendor_redroid
- Docker kernel check: https://github.com/moby/moby/blob/master/contrib/check-config.sh
