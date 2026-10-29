# A733 Android farm: PowerVR GPU inside redroid

Goal: run 2 Android instances on each Allwinner A733 board (Orange Pi Zero 3W / Zero 4). Each instance is a redroid container, and the PowerVR BXM-4-64 GPU does the rendering.

Pilot board: **Orange Pi Zero 3W, 6 GB**, with a USB-C GbE dongle (section 8). The scripts work unchanged on the Zero 4.

Status on 2026-10-28. Everything that can be built or checked without an A733 board has been done.

**Update 2026-10-29: the A733 GPU has an open stack coming** (section 16.8).
- The SpacemiT K3 has the **same GPU revision** (BXM-4-64, BVNC 36.56.104.183).
- Imagination's open-source firmware for it (fw 1.1 build 6976702) is public: fetch group `fw`, sha256-pinned.
- Mesa lists 36.56.104.183 as "in active development".
- BayLibre's Android 17 for the K3 runs fully open (upstream `drm/imagination` + Mesa + minigbm). That is **Route M**.
- **On board day:** test order stays Route L → Route A, plus an optional firmware-1.1 test in Route L (BOARD-DAY step 4c).
- **To keep following mainline:** `python3 -I scripts/60-mainline-watch.py` (section 16.9).

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

## 1. Is there a working PowerVR stack for A733 to build on? Yes, five

| Stack | What it is | Where | Role here |
|---|---|---|---|
| **Vendor Android 13** | Allwinner's Android userspace: EGL, GLES 3.2, Vulkan, gralloc 4, OpenCL, **DDK 24.2@6643903**. Also the **kernel driver source of the same build** (MIT/GPL). | `gitlab.com/aw_android13/gpu/gpu` and `.../lichee/bsp` → `modules/gpu/img-bxm/android/rogue_km`, branch `a733-radxa-v1.0` (Radxa's public A733 Android 13 SDK) | **Plan A.** Both halves come from one build. |
| Vendor Linux (Orange Pi 6.6 BSP) | Upstream-style PowerVR driver in `bsp/drivers/gpu/imagination` (`CONFIG_AW_DRM_POWERVR`, binds `img,gpu`, manual clock-and-reset power sequence). Firmware `powervr/rogue_36.56.104.183_v1.fw` from Allwinner's libgpu. Userspace is unpatched Mesa ≥ 25.3 (it already has this BVNC's device info) with `PVR_I_WANT_A_BROKEN_VULKAN_DRIVER=1`, not apercel's Mesa patch (that renames the driver to `apercel`); libgpu's DDK 24.2@6603887 libraries expect the DDK kernel UAPI (section 16.7). | Orange Pi kernel `bsp/` (`2ac08e8c`) and `gitlab.com/tina5.0_aiot/product/linux/external/libgpu` (`144487e8`) | **Route L** (section 16.6): the first GPU test. The option is off in every Orange Pi config we checked, so nobody has shipped this driver here. The module builds on the build PC (2026-10-28) but has not run. |
| AIoT rogue_km (tina5 BSP) | DDK-style Linux driver for BVNC 36.56.104.183 (`RGX_BVNC := 36.56.104.183`), DDK 24.2@6603887, with `sunxi_secure_config()` | `gitlab.com/tina5.0_aiot/lichee/bsp` → `modules/gpu/img-bxm/linux/rogue_km` (`a5fe1970`) | Origin of the secure-reset step (section 4). Not what the Orange Pi 6.6 tree builds. |
| Radxa A733 Bullseye image (reference) | Radxa's prebuilt Linux GPU stack for A733: DKMS `img-bxm-dkms` 0.1.0-2, `pvrsrvkm.ko` for kernel 5.15.147-14-a733 (DDK 24.2@6603887, Linux WS build), IMG user-space 24.2.6603887, firmware `rgx.fw` / `rgx.sh` 36.56.104.183 | Public apt repo `radxa-repo.github.io/a733-bullseye`; image `radxa-a733_bullseye_kde_r2.output_512.img.xz` (sha256 `1b5604fe…`) | Reference only. Compare the Linux driver and its start sequence. Not a base: 5.15 kernel. Mirror the repo before it disappears. |
| Open source | `apercel` (Oct 2026): the upstream `drm/imagination` driver built out of tree, plus a patch to Mesa 26.1.8 for BVNC 36.56.104.183. Vulkan + Zink, tested on an Orange Pi 4 Pro (A733). Linux 7.3 lists BXM-4-64 MC1 (TH1520) as supported; Mesa BXM-4-64 isn't conformant yet. | github.com/TumRedSun/apercel | Plan B (section 13), and an upstream opportunity. |
| **Open stack, same GPU (SpacemiT K3)** | The K3 has BXM-4-64 at **BVNC 36.56.104.183**, the same as the A733. Imagination's open-source firmware `rogue_36.56.104.183_v1.fw` is **fw 1.1 build 6976702**, newer than libgpu's 1.0 build 6852738. Mesa's docs list 36.56.104.183 as "in active development". BayLibre's **Android 17** for the K3: upstream `drm/imagination` + Mesa ≥ 26.1 (PowerVR Vulkan + Zink GLES) + minigbm `gbm_mesa` + hwc3 drm. | `BayLibre/android_device_spacemit_k3` (`06c4578e`), `BayLibre/android_device_spacemit_common` (`755c243b`), `BayLibre/mesa`; fetch group `fw` | **Route M** (section 16.8): the long-term open path for redroid. No DDK matching and no blobs. |

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
3.a733-android-farm/                     (tracked in git: README, BOARD-DAY.md, KIT-SHA256.txt, config/, scripts/)
├── BOARD-DAY.md                         first-session runbook for the Zero 3W (serial, rollback, Route L/A, fw 1.1 test)
├── KIT-SHA256.txt                       hashes of the kit built on the build PC
├── config/
│   ├── linux-sun60iw2-current-a733.config         Orange Pi's kernel config (orangepi-build a95129bf3)
│   ├── redroid-host.fragment                      options added on top of it
│   ├── pvrsrvkm-android-sunxi-secure-config.patch GPU secure-reset fix (section 4)
│   ├── vendor_redroid-gpu_config-pvr.patch        PowerVR case for source-built redroid
│   ├── redroid-13-gpu_config.orig.sh              redroid's own GPU script (overlay fallback)
│   ├── headers-debian-byteshift.patch             needed by Orange Pi's builddeb
│   ├── mesa-android-aarch64-api33.ini             Meson cross file, NDK r29, API 33 (Route M)
│   └── mesa-pvr-accept-apercel-drm-name.patch     Mesa binds to `powervr` and `apercel` DRM names
├── scripts/
│   ├── env.sh                           toolchain + paths
│   ├── 00-fetch-sources.sh              recreate src/ at pinned commits (groups: kernel gpu ref fw apercel)
│   ├── 10-build-host-kernel.sh          kernel + fragment
│   ├── 15-package-kernel-deb.sh         -> linux-image/dtb/headers .deb
│   ├── 20-build-pvrsrvkm-android.sh     Android-flavour GPU driver (+ patch; SECURE_CONFIG=0 = fallback without it)
│   ├── 22-build-apercel.sh              open host GPU driver apercel + 3 DRM helper modules -> out/apercel/
│   ├── 23-build-mesa-android.sh         Route M: Mesa 26.3 PowerVR + Zink for redroid 13 arm64 (VARIANT=apercel)
│   ├── 24-mesa-shim-probe.sh            Route M without a board: Vulkan features + Zink GL level via drm-shim
│   ├── mesa_glver.c, mesa_glsmoke.c     (used by 24: highest GL/GLES context; GLES 3.1 smoke test)
│   ├── 25-check-km-um-match.sh          static connect-handshake check
│   ├── 26-check-blobs-vs-redroid.sh     static link check vs the real redroid image
│   ├── redroid_link_check.py            (used by 26)
│   ├── 30-make-redroid-pvr-context.sh   overlay image context (stock redroid + blobs)
│   ├── 31-make-aosp-vendor-tree.sh      vendor/powervr-a733 for SOURCE-built redroid
│   ├── 32-make-redroid-mesa-context.sh  Route M overlay image context + link check vs redroid 13
│   ├── 35-test-on-redroid-host.sh       RUN ON YOUR OTHER REDROID PC
│   ├── 40-board-setup.sh                RUN ON THE A733 BOARD
│   ├── 45-usb-net.sh                    board, optional: USB GbE dongle or USB NCM gadget
│   ├── 50-board-report.sh               board: PASS / WARN / FAIL report + evidence folder
│   └── 60-mainline-watch.py             any PC: re-check mainline/next/firmware/Mesa/patchwork, diff vs last run
├── src/   (git-ignored; 00-fetch-sources.sh)
└── out/   (git-ignored; contains vendor blobs, do not publish)
    ├── fw/1.0, fw/1.1                   the two GPU firmware files, staged for the board (BOARD-DAY step 3)
    └── mainline-watch/<date>.json       60-mainline-watch.py snapshots (per PC; baseline values in 16.9)
```

## 4. Bring-up risk found and fixed: platform glue differences

The Android driver (Radxa SDK, Aug 2025) and the AIoT rogue_km (Allwinner v1.5.0, 2026) share the same core. Their A733 glue (`services/system/rogue/rgx_sunxi`) differs. The Orange Pi 6.6 driver (`bsp/drivers/gpu/imagination`) is a different, upstream-style driver with no such glue (section 16.6):

| Difference | Effect on Orange Pi boards | Action |
|---|---|---|
| The AIoT rogue_km calls `sunxi_secure_config()` before **every** GPU start (`RGXDoStart` → `pfnTDSystemSecureConfig`). It writes `0x2` to `0x0a0000b0` (releases the GPU "DRM"/secure reset in the SMC) and `0` to `0x01880014` (`GPU_GLB.DRM_CTRL`). The older Android core has no such hook. The Orange Pi 6.6 driver and the Radxa DKMS driver don't make this call. | Unverified. The step may matter only on the AIoT path. Route L will show whether the 6.6 driver boots without it. | **Ported** (Android flavour only): runs in `sunxiPrePowerState` after clocks and power are on, before `RGXStart`. Route L runs without it. |
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

### 8.2 Board choice revisited: A733 vs RK3588 vs RK3399, local prices 2026-10-29

Prices are the user's local quotes in million VND ("tr"). Instance counts are estimates from section 8.1: 1.3–1.9 GB RAM per instance, and about one A76-class core per instance that plays video with software decoding. CPU "units" = A76 @ 2.0 GHz = 1; A55 @ 1.8 GHz ≈ 0.38; A76 @ 2.4 GHz ≈ 1.2; A72 @ 1.8 GHz ≈ 0.68; A53 @ 1.4 GHz ≈ 0.27.

| SoC | CPU units | RAM bus | GPU | GPU in redroid today |
|---|---|---|---|---|
| A733 (2×A76 + 6×A55) | ≈ 4.3 | 32-bit LPDDR5 (A733 manual) | BXM-4-64 MC1 | not proven: Route A (vendor DDK, deadlock reports) or Route M (our Mesa build) |
| RK3588/RK3588S (4×A76 @ 2.4 + 4×A55) | ≈ 6.3 | 64-bit | Mali-G610 MP4, several times the BXM-4-64 | proven: vendor 6.1 kernel + libmali images (`cnflysky/redroid-rk3588`, `/dev/mali0`), or mainline panthor + Mesa panfrost/panvk (upstream Mesa has Android support, so scripts 23/32 could be retargeted) |
| RK3399 (2×A72 + 4×A53) | ≈ 2.4 | 64-bit LPDDR4 | Mali-T860 MP4 | panfrost is in redroid's own Mesa and its `gpu_config.sh` list; GLES 3.1, no Vulkan |

| Option | Price | Instances (est.) | tr per instance | Notes |
|---|---|---|---|---|
| 3 × Orange Pi 4 Pro A733 6 GB | 7.8 | 6 | 1.30 | cheapest on paper; 3 PSUs and 3 network ports; GPU path unproven |
| 1 × Orange Pi 5 Plus 8 GB | 6.6 | 4 (RAM-bound) | 1.65 | cannot hold 6 TikTok instances in 8 GB |
| 1 × Orange Pi 5 Plus 16 GB | 10.3 | 6 (CPU-tight with software decode) | 1.72 | 2× 2.5GbE, PCIe 3.0 x4 NVMe |
| 1 × Orange Pi 5 Pro 16 GB | 9.6 | 6 (CPU-tight) | 1.60 | LPDDR5 |
| 2 × Orange Pi 5 Pro 8 GB (if 4.7 tr is the 8 GB price; the 5 Pro comes in 4/8/16 GB, not 6) | 9.4 | 8 (6 with headroom) | 1.18 | best balance if that price holds |
| 2 × Orange Pi 5 4 GB | 7.2 | 4 | 1.80 | RAM-bound |
| 1 × Orange Pi 5B 16 GB / 128 GB eMMC | 12.8 | 6 (CPU-tight) | 2.13 | storage included |
| 1 × Orange Pi 4 LTS RK3399 4 GB | 2.0 | 1–2 | 1.0–2.0 | old and weak; useful as a fully mainline learning board, not for the farm |

Reading:
- **RK3399 vs A733 at a similar price: A733.** It has about 1.8× the CPU, 6 GB LPDDR5 instead of 4 GB, and newer cores. RK3399's only advantages are full mainline support and panfrost working in stock redroid.
- **One RK3588 with 8 GB does not reach 6 instances; RAM limits it.** Two RK3588 boards with 8 GB each give the same CPU per instance as 3 × A733 (about 1.6 units) plus a much stronger GPU and twice the memory bus, with a GPU path that already works in redroid.
- One RK3588 with 16 GB fits 6 instances in RAM, but its 4 A76 cores are tight for 6 software video decoders. That changes only if the Rockchip video decoder (MPP) is wired into the containers.
- **Plan:** let the Zero 3W board day decide. If Route A or M runs TikTok smoothly on 2 instances, the A733 stays the cheapest per instance. If not, move the farm to RK3588 (2 × 8 GB, or 1 × 16 GB for lighter apps), and keep the A733 as the course and upstream board.

**Update from the user's own RK3588 test (2026-10-29): an RK3588 board tops out at 3 instances.** At 4 the CPU gives out before RAM does. With 3 per board, RK3588 costs at least about 1.6 tr per instance (Orange Pi 5 Pro, if 4.7 tr is the 8 GB price) and up to 2.2 tr (5 Plus 8 GB at 6.6 tr). That loses to **3 A733 boards × 2 instances**, provided the A733 runs 2 instances smoothly (the board-day question).

### 8.3 Which A733 board for the farm; the Zero 2W expansion board does not fit the Zero 3W

**The Zero 2W expansion board is not compatible with the Zero 3W.** Don't plug it in.
- The Zero 2W's 24-pin "function" FPC carries the H618's two USB 2.0 ports, the H618's **internal** 10/100 Ethernet PHY (analogue pairs straight to the RJ45 magnetics on the hat; there is no PHY chip on the hat), audio, TV-out, IR and buttons.
- The Zero 3W has no such connector. Its FPC is **PCIe 3.0 x1** (official spec: "1 x PCIe 3.0 1-Lane FPC socket"), and the A733 has no internal Ethernet PHY: its GMAC needs an external PHY, like the YT8531 on the Orange Pi 4 Pro. So the hat's Ethernet cannot work, and mismatched pins could put supply voltage on the PCIe lanes.
- Wired network options for the Zero 3W:
  - the **USB-C GbE dongle** already planned (RTL8153, `r8152` module; `45-usb-net.sh`). Two instances need a few Mbit/s each, so USB GbE is plenty.
  - A **PCIe FPC adapter + PCIe NIC**. The stock Zero 3W DT enables the PCIe root complex (`pcie@6000000`, Gen3 x1) and its combo PHY. But the FPC pinout is not documented as Raspberry Pi 5-compatible (check the Zero 3W schematic before buying a Pi 5 HAT), and our kernel config has `CONFIG_R8169` off; it is a one-line addition to the fragment.

| Per board (6 GB) | Wired network | Other I/O | Size | Local price (2026-10-29) / official | Notes |
|---|---|---|---|---|---|
| Orange Pi Zero 3W | none: USB-C GbE dongle | 1× USB 3.1 Type-C (DP alt), PCIe FPC | 65 × 32 mm | **2.4 tr** + dongle / $60 | the pilot board; boot0 runs LPDDR5 at 2400 MHz |
| **Orange Pi Zero 4** | **GbE RJ45 onboard** | — | small | **2.4 tr** / $63 | Orange Pi's build gives it **the Zero 3W's boot0** (`sun60iw2.conf`), so DRAM at 2400 MHz too |
| Orange Pi 4 Pro | GbE RJ45 (YT8531), optional PoE module | 1× USB 3.0 + 3× USB 2.0 host, M.2 M-key PCIe 3.0 (NVMe), eMMC socket | 89 × 56 mm | **2.7 tr** / $40 | no board-specific boot0, so Orange Pi's build falls back to the generic `boot0_sdcard_a733.fex`: DRAM at **1800 MHz**, about 25% less memory bandwidth |

All three use the same SoC, kernel (`sun60i-a733-orangepi-{zero3w,zero4,4-pro}.dtb` are all in our tree), images and scripts. **At local prices, the Zero 4 is the farm board:** same price as the Zero 3W, GbE onboard (no dongle, no USB failure point), and the same 2400 MHz DRAM. The 4 Pro costs 0.3 tr more for PoE, NVMe and USB-A, which the farm doesn't need, and its DRAM runs 25% slower unless the DDR study shows it can run faster. The Zero 3W stays the pilot, course and upstream board.

## 9. On the A733 board

1. Flash the Orange Pi Debian **trixie 1.0.2 server** image (`Orangepizero3w_1.0.2_debian_trixie_server_linux6.6.98.7z`; Debian 13.6, kernel 6.6.98-sun60iw2). It has no PowerVR driver; the kit provides it.
2. `rsync -a out/deploy out/redroid-pvr scripts/40-board-setup.sh scripts/45-usb-net.sh scripts/50-board-report.sh orangepi@<ip>:~/farm/`, plus `redroid-pvr-13-arm64.tar` if you built one.
3. On the board:
   ```bash
   ./40-board-setup.sh kernel && sudo reboot    # replaces /boot/uImage (the stock one comes back with the rollback below)
   ./40-board-setup.sh run                      # GPU driver + firmware, image, 2 pinned instances
   ./50-board-report.sh                         # PASS / WARN / FAIL for section 10, evidence in ~/farm/reports/
   ```
   - Before step 3, back up the stock kernel: `sudo tar -C / -cpf ~/stock-kernel-backup.tar boot usr/lib/modules/6.6.98-sun60iw2`.
   - Rollback: `sudo tar -C / -xpf ~/stock-kernel-backup.tar && sudo reboot`. The image's apt lists have no Orange Pi kernel index, so apt cannot reinstall the stock kernel.
   - Instances: CPUs `1,2,5,6` / `3,4,5,7` (host stays on cpu0), `--memory=2200m` on 6 GB (1600m under 5 GB), zram 2 GB, 720×1280 at 30 fps, adb 5555/5556.
   - Board-day order, serial console and fallbacks: [BOARD-DAY.md](BOARD-DAY.md).
   - GPU order: Route L first (section 16.6), then `40-board-setup.sh run`. Both drivers bind `img,gpu`, so unload one before loading the other.

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
| GPU firmware won't boot / GPU bus hang | **high** | With the cores halted, or live through a MEM-AP, read `0x0a0000b0`, `0x01880014` and the GPU registers at `0x01800000`. Reference: Route L (the Orange Pi 6.6 driver, section 16.6) writes neither `0x0a0000b0`, `0x01880014` nor the PPU register `0x07066000`. The AIoT rogue_km writes the first two. Compare the two driver logs before blaming the power sequence. Shows whether the secure reset is released and whether the CPU is stuck in a GPU register access. |
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

- **Plan B, open stack = Route M (section 16.8).**
  - Host: `apercel` / upstream-style `drm/imagination` with Imagination's fw 1.1.
  - Container: Mesa's PowerVR Vulkan + Zink for GLES, minigbm `gbm_mesa` gralloc, and the hwc3 drm composer. BayLibre ships exactly this for the same GPU on the K3 (Android 17).
  - No DDK matching, upstreamable.
  - Risks: non-conformant Vulkan 1.2 (needs `PVR_I_WANT_A_BROKEN_VULKAN_DRIVER=1`), and redroid's Mesa must be rebuilt with `imagination` + `zink`.
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
| BayLibre/android_device_spacemit_k3 | android-17 | 06c4578ef (2026-09-18); firmware file from a09d86fe4 |
| BayLibre/android_device_spacemit_common | android-16 | 755c243bb (2026-06-15) |
| Imagination fw for 36.56.104.183 (via BayLibre) | — | fw 1.1 build 6976702, 131,072 B, sha256 `1db1c399c17401d1f79d46c880db81c724d748c784d4639433b076aba2f9c0d2` |

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
- Orange Pi 6.6 kernel tree (PowerVR driver, PCK-600, CCU, board DTS): https://github.com/orangepi-xunlong/linux-orangepi
- Orange Pi build (kernel configs): https://github.com/orangepi-xunlong/orangepi-build
- Mainline DRM driver: https://github.com/torvalds/linux/tree/master/drivers/gpu/drm/imagination
- Mesa PowerVR source (freedesktop, main): https://gitlab.freedesktop.org/mesa/mesa/-/tree/main/src/imagination
- linux-riscv mailing-list archive (lists.infradead.org; the A733 CCU v5 thread in section 16.3) and linux-firmware (GitLab, `powervr/`), both checked 2026-10-28
- SpacemiT K3 GPU (section 16.8):
  - BayLibre K3 AOSP: https://github.com/BayLibre/android_device_spacemit_k3, https://github.com/BayLibre/android_device_spacemit_common, https://github.com/BayLibre/mesa
  - K3 binding v3 and review: https://lkml.iu.edu/2607.3/06724.html, https://lkml.iu.edu/2607.3/10035.html; probe without power-domains (superseded): https://lkml.iu.edu/2607.3/06720.html; merged K1/K3 binding: https://patchwork.kernel.org/project/devicetree/patch/20261015-spacemit-gpu-binding-v1-1-a7a23c7e7788@linux.spacemit.com/
- apercel on the Zero 3W (section 16.10): report https://github.com/TumRedSun/apercel/issues/1, fork https://github.com/CheezeCS/apercel, Armbian integration https://github.com/CheezeCS/armbian-a733-gpu, Mesa transform feedback for PowerVR: mesa!44385
  - openRuyi K3 firmware issue: https://github.com/openRuyi-Project/kernel-team-tools/issues/29
  - Phoronix BXM-4-64 firmware: https://www.phoronix.com/news/IMG-PowerVR-BXM-4-64-FW
- AXP318W (= vendor AXP8191 / AXP819, section 16.5): https://patchew.org/linux/20260710-axp318-regulator-v2-0-ee5f1c56b49f@baylibre.com/, U-Boot https://lists.denx.de/pipermail/u-boot/2026-January/606579.html

## 16. Mainline status and upstream commits (checked 2026-10-28; GPU, PMIC and firmware re-checked 2026-10-29)

Checked against `torvalds/linux` (latest tag v7.3; master carries the 7.4 work), the linux-riscv archive (lists.infradead.org), linux-firmware (gitlab raw) and the apercel project. "In v7.3" means GitHub's compare against `v7.3` returned `behind`, so the commit is an ancestor of the tag. lore.kernel.org showed a bot check to this environment and linux-sunxi.org returned 403, so those two were read only through search snippets. Nothing here has run on hardware.

**Bottom line.** Mainline cannot drive this A733 GPU today. It has the A733 power-domain controller and RTC clocks, and A733 pinctrl is queued for 7.4. Its PowerVR driver supports BXM-4-64 only for the TH1520's BVNC (36.52.104.182). Mainline has no A733 CCU, no A733 device tree, no A733 MMC driver, no BVNC entry for our 36.56.104.183, and no firmware for it. The Orange Pi Zero 3W is not in mainline.

### 16.1 In mainline v7.3

```
a46e905cd14a0a82b6f1fbf2f720fe5f13755050  2026-03-05  pmdomain: sunxi: Add support for A733 to Allwinner PCK600 driver
f287826fd7e406caa56692ecc39742bdb312b2e8  2026-03-05  dt-bindings: power: Add Support for Allwinner A733 PCK600 Power Domain Controller
b462a227d8547d62b1f654bf80b3505a84746b54  2026-05-10  pmdomain: sunxi: support power domain flags for pck600
38d6b194a21c8626647b0a773bb8db5f2b84b0ad  2026-07-06  dt-bindings: rtc: sun6i: add sun60i-a733 support
0a136efc0fc2d53b1b1389b3c3fb0f76edca38bf  2026-07-23  clk: sunxi-ng: sun6i-rtc: add a733 support
8dc697aabf7c49f1d40351f21e13a22ee030f508  2026-07-31  dt-bindings: mmc: sunxi: add compatible string for Allwinner A733 MMC0/1/2
e55fead22ff9ee047ab9f1903860c4b43043514e  2026-07-20  drm/imagination: promote BXM-4-64 MC1 (36.52.104.182) to supported status
9b33d8e063f62074b729c52b052cc306b9369714  2026-07-20  drm/imagination: update GPU support documentation
5052d5cf1359e9057ec311788c12997406fdb2fc  2025-08-22  riscv: dts: thead: th1520: Add IMG BXM-4-64 GPU node
337ebfda8a4f2627bf52e200cacf6f3a2f5ccf48  2025-08-22  dt-bindings: gpu: img,powervr-rogue: Add TH1520 GPU support
6b53cf48d9339c75fa51927b0a67d8a6751066bd  2025-08-22  drm/imagination: Enable PowerVR driver for RISC-V
d4c2d9b5b7ceed14a3a835fd969bb0699b9608d3  2025-06-23  power: sequencing: Add T-HEAD TH1520 GPU power sequencer driver
```

The PCK-600 commits give the A733 domains: `PD_GPU_TOP` = 5 and `PD_GPU_CORE` = 6. The TH1520 commits show the mainline BXM-4-64 device-tree pattern.

### 16.2 Queued for 7.4 (on master, not in v7.3)

```
0535bfbfa97bd3fe43749952756ef08917b31e48  2026-09-10  pinctrl: sunxi: add support for the Allwinner A733
3fa025dfe1e7be11ea9cd2174666d1f953a61226  2026-09-10  pinctrl: sunxi: support A733 generation MMIO register layout
5777ddfb5f361269e26a1989c9da774e3349c639  2026-09-10  dt-bindings: pinctrl: add compatible for Allwinner A733
0da2c96cf69df277275b3e7e57118a34b50c8177  2026-09-24  dt-bindings: i2c: mv64xxx: Add Allwinner A733 compatible string
```

The first adds `pinctrl-sun60i-a733.c`. The I2C commit is binding-only.

### 16.3 Missing upstream (no commit found)

| Needed | Checked | Status |
|---|---|---|
| A733 CCU and PRCM clock driver | `drivers/clk/sunxi-ng/` has no sun60i file | In review: "[PATCH v5 0/8] clk: sunxi-ng: Add support for Allwinner A733 CCU and PRCM" (linux-riscv archive, message 100638; patch 3/8 "clk: sunxi-ng: a733: Add PRCM CCU"). Reviewer Chen-Yu Tsai (3 Oct 2026) raised secure-by-default PLLs and bus dividers, and a secure-only TWD clock. |
| A733 device tree and Zero 3W board DTS | no sun60i or orangepi-zero3w file in `arch/arm64/boot/dts/allwinner` | No patch found in our searches |
| BVNC 36.56.104.183 (our GPU) | `pvr_gpu_support_level()` in `pvr_device.c` marks 33.15.11.3 (the AXE-1-16M the docs list), 36.52.104.182 (BXM-4-64, TH1520) and 36.53.104.796 (the BXS-4-64 MC1 the docs list) as supported. 36.56.104.183 is absent (re-checked in mainline and linux-next 2026-10-29). | Missing in the driver. Mainline refuses unknown BVNCs unless `exp_hw_support=1` is set; with it, it warns "Running on unknown hardware; expect issues" and continues. The Orange Pi 6.6 driver has no BVNC table. **Mesa: supported as a device, not conformant.** Device info `pvr_device_info_36_56_104_183` (`src/imagination/common/device_info/bxm-4-64.h`, `pvr_device_info.c`) came in `1db1038a61a` (Alessio Belle, Imagination, MR !37790, merged 2025-10-11), so every Mesa since **25.3.0** knows this GPU. The `pvr_physical_device.c` switch read on 2026-10-28 is `pvr_device_is_conformant()`: it only decides whether `PVR_I_WANT_A_BROKEN_VULKAN_DRIVER=1` is needed (main and 26.3: 36.52.104.182 and 36.53.104.796). Corrected 2026-10-29 from a clone of Mesa main `1c3a936490f`. |
| GPU binding for A733 | `img,powervr-rogue.yaml`: no Allwinner entry | Missing. The mainline BXM-4-64 entry is now `enum: [spacemit,k3-gpu, thead,th1520-gpu]` + `img,img-bxm-4-64` + `img,img-rogue`. `spacemit,k1-gpu` and `spacemit,k3-gpu` were merged in `16f30811a935` (2026-10-15, Baihui Liang). An A733 entry would join that enum. The vendor tree and the kit's driver use `img,gpu`. |
| GPU firmware `rogue_36.56.104.183_v1.fw` | linux-firmware `powervr/` main has only 33.15.11.3, 36.52.104.182 and 36.53.104.796 (re-checked 2026-10-29) | Not in linux-firmware main. **Imagination's open-source build exists:** fw 1.1 build 6976702, vendored in BayLibre's K3 tree (fetch group `fw`, section 16.8). Allwinner's libgpu has the older 1.0 build 6852738 (section 16.7). |
| A733 sunxi MMC driver | `drivers/mmc/host/sunxi-mmc.c`: no A733 match | Binding only (`8dc697aa…`) |
| AXP318W regulators | `drivers/regulator/axp20x-regulator.c` and `drivers/mfd/axp20x.c`: no axp318w (mainline and linux-next, re-checked 2026-10-29) | Andre Przywara's series (RFC 2025-08) is at **v8** (2026-09-10): "mfd: axp20x: Add support for AXP318W PMIC", "regulator: axp20x: add support for the AXP318W", and the binding in `x-powers,axp152`. Patchwork marks the MFD/regulator patches "handled-elsewhere", most likely picked up by the subsystem maintainer. Expect it in 7.4 or 7.5. |

### 16.4 Out of tree

- **apercel** (https://github.com/TumRedSun/apercel): a kernel driver built from upstream drm/imagination for the 6.6.98-sun60iw2 BSP (module `apercel`), plus a Mesa 26.1.8 patch for BVNC 36.56.104.183. Self-reported on one board, an Orange Pi 4 Pro (A733), with the GPU at 1.008 GHz. Its power-on is `clk_parent`, `clk`, `clk_bus`, a 1 µs delay, then one `reset_control_deassert`. A grep of its driver source finds no `0x0a0000b0`, no `0x01880014` (DRM_CTRL), no `0x07066000` (PPU) and no `0x02002b20` (GPU clock register). Its README says it binds by `img,gpu`.
- **Radxa A733 Bullseye image** (`prebuilt-image/radxa-a733_bullseye_kde_r2.output_512.img.xz`, sha256 `1b5604fe…`): ships a vendor Linux driver as DKMS package `img-bxm-dkms` 0.1.0-2 (DDK 24.2@6603887, Linux WS build), a built `pvrsrvkm.ko.xz` for kernel 5.15.147-14-a733, IMG user-space 24.2.6603887, and firmware 36.56.104.183. Its `rgx.sh` is byte-identical to the kit's. Its `rgx.fw` is not.

### 16.5 What this means for us

1. **The power domains are mainline-shaped.** The A733 PCK-600 driver puts each domain's PPU block at `base + 0x1000 × index`. Domain 5 (GPU_TOP) is at `0x07065000`, and domain 6 (GPU_CORE) is at `0x07066000`, the address the kit writes `0x8` to (`PPU_PWPR`, `POWER_MODE_ON`). The Zero 3W tree requests domain 5 only. The Orange Pi 6.6 SoC DT keeps its GPU_CORE node commented out, and Route L doesn't need GPU_CORE. The Android path does the manual write, as the vendor Android does. Board check: read `PPU_PWSR` (+0x8, bits 3:0) at `0x07065008` and `0x07066008`; `0x8` means on. Read both before loading the driver and after the write.
2. **The minimal sequence is the vendor's Linux one.** The Orange Pi 6.6 driver powers the GPU with `clk_parent`, `clk` and `clk_bus`, a 1 µs delay, then one reset deassert: the same code apercel uses. No PPU, secure or bit-27 write. Route L tests that path on our board. The Android path keeps the writes the vendor Android and AIoT code make.
3. **Secure-by-default clocks.** The CCU review says the A733's PLLs and bus dividers are secure by default, and asks whether things work only because secure boot is not enforced. One tester reports the registers work on a Radxa Cubie A7S without secure boot. Those measurements are AI-assisted, and the author asks that they not count as Tested-by.
4. **PMIC naming: almost certainly one part.** Every vendor device tree we checked defines `x-powers,axp8191`: both Orange Pi trees, and Radxa's Cubie A7A, A7S and A7Z. The Zero 3W schematic and mainline say AXP318W, and the U-Boot AXP318W series says the part is called "AXP819" in vendor PMU code.
   - **So don't write a new AXP8191 driver.** Give `Tested-by` on Andre's AXP318W series (v8) from the Zero 3W instead.
   - Board check: read the PMIC's chip-ID register over I2C and compare it with the ID in the AXP318W driver.
5. **Names differ from mainline.** The PCK-600 compatible is `allwinner,sun60i-a733-pck-600` upstream and `allwinner,sun60iw2-pck-600` in the Zero 3W tree. Firmware is named `rogue_<BVNC>_v1.fw` upstream and `rgx.fw.<BVNC>` in the vendor tree.

Upstream does not run the Zero 3W. Its mainline gaps are the CCU, the device tree, the BVNC and the firmware. Those are the commits to watch, or to write, if we want a mainline path.

### 16.6 GPU routes and test order

Five ways to drive this GPU on our board, ordered by evidence and by how much each test tells us.

| Route | Driver | Firmware | Userspace | Status |
|---|---|---|---|---|
| **L** Linux host | Orange Pi 6.6 BSP `bsp/drivers/gpu/imagination` (`CONFIG_AW_DRM_POWERVR=m`), binds `img,gpu` | `/lib/firmware/powervr/rogue_36.56.104.183_v1.fw` (libgpu, v3, open-source) | Unpatched Mesa ≥ 25.3 (≥ 26.3 for GLES 3.x via Zink) with `PVR_I_WANT_A_BROKEN_VULKAN_DRIVER=1`. Not apercel's Mesa patch (driver name `apercel`), not libgpu's DDK libraries (section 16.7). | Comparison test after apercel. Module builds (2026-10-28, `out/route-l/` on the build PC); not run. |
| **A** redroid | kit's `pvrsrvkm-android.ko` (Android DDK 6643903) | `/lib/firmware/rgx.fw.36.56.104.183` (Android copy) | Android blobs in the container | Built, never run. Keeps the PPU, secure and bit-27 writes. Fallback without the secure port: `pvrsrvkm-android-nosecure.ko` (`SECURE_CONFIG=0`, section 16.12). Risk: the vendor-DDK deadlock seen with live compositors (16.12). |
| apercel (**now first host test**, section 16.10) | out-of-tree kbuild module `apercel`; use the CheezeCS fork (+30 upstream fixes), `scripts/22-build-apercel.sh` | `/lib/firmware/apercel/rogue_36.56.104.183_v1.fw`: Imagination fw 1.1 (fetch group `fw`) | Mesa 26.3 with the fork's `mesa/apercel-mesa-26.3.0-rc2.patch` (GLES 3.1 via Zink) | **Proven on an Orange Pi Zero 3W** by CheezeCS (2026-10-25, same vendor kernel tree, same firmware). Not yet on ours. |
| Radxa DKMS (reference) | DDK 6603887, Rogue style, for 5.15 | Radxa `rgx.fw` (v2, not open-source) | Radxa libraries | Not for our 6.6 kernel. |
| **M** open stack (planned) | Route L's driver, or `apercel` / mainline `drm/imagination` (`exp_hw_support=1` until the BVNC is listed) | Imagination **fw 1.1 build 6976702** (`src/firmware/imagination-fw-1.1/`, sha256 `1db1c399…`) | redroid overlay with Mesa 26.3 PowerVR Vulkan + Zink (BayLibre's Android commits rebased), redroid's own gbm_gralloc and fake composer (section 16.11) | Plan only. Start after apercel or Route L shows the GPU probes and its firmware boots. |

**Route L, step by step.** Step 1 runs on the build PC.
1. Build PC, done 2026-10-28 in a copy of the kit tree (`/mnt/project/route-l-build/linux-orangepi-6.6`; the kit tree itself was not changed). `CONFIG_AW_DRM_POWERVR=m` and `make olddefconfig` add three helper modules that the kit's `.config` did not have: `CONFIG_DRM_EXEC=m`, `CONFIG_DRM_GEM_SHMEM_HELPER=m` and `CONFIG_DRM_SCHED=m`. Five config lines change in all (`out/route-l/config-delta.txt`). Then `make modules_prepare`, `make modules` and `make M=bsp/drivers/gpu/imagination modules` all exit 0. The one warning is an unused variable in the BSP's `drm_gpuvm.c`. `powervr.ko` has vermagic `6.6.98-sun60iw2-redroid SMP preempt mod_unload aarch64`, needs `gpu-sched`, `drm_shmem_helper` and `drm_exec`, and matches `img,gpu` (`of:N*T*Cimg,gpuC*`). MODVERSIONS is off in the kit config, so a load checks vermagic only. The four modules and their hashes are in `out/route-l/` on the build PC (`SHA256SUMS`). Not run on hardware yet.
2. Board: install the firmware with `sudo install -D -m 0644 rogue_36.56.104.183_v1.fw /lib/firmware/powervr/rogue_36.56.104.183_v1.fw` (sha256 `3974e79f…`). Keep the four modules in `~/farm/route-l/`: don't copy them into `/lib/modules` or run `depmod`, or udev autoloads an `img,gpu` driver at every boot and Route A loses the GPU (BOARD-DAY 4a).
3. Board: unload `pvrsrvkm` or apercel if loaded, then `insmod` `gpu-sched.ko`, `drm_exec.ko`, `drm_shmem_helper.ko` (skip any already loaded) and `powervr.ko`.
4. Check `dmesg` for `loaded firmware powervr/rogue_36.56.104.183_v1.fw` and `FW version v1.0 (build 6852738 OS)`. Then `ls /dev/dri` (card0 and renderD128) and `cat /sys/kernel/debug/dri/*/name` (expect `powervr`).
5. Userspace comes after the module works, and it is not libgpu's. libgpu's libraries are DDK 24.2 builds, and `libsrv_um` calls `DRM_IOCTL_PVR_SRVKM_INIT`, which the upstream UAPI (`pvr_drm.h`) does not define. Use unpatched Mesa ≥ 25.3 (Mesa finds the device by DRM name `powervr`, which this driver reports), then `PVR_I_WANT_A_BROKEN_VULKAN_DRIVER=1 vulkaninfo --summary`. apercel's Mesa patch would look for `apercel` instead and find nothing. Not tried.
6. PD readbacks before and after step 3: `devmem 0x07065008` and `devmem 0x07066008`. `0x8` means on.

Firmware errors look different from hardware errors. `firmware not available yet, deferring` means the file is missing or in the wrong path. `Unsupported fw info version 2` means the older info format; the Radxa and Android `rgx.fw` copies are info v2. `FW info format mismatch` means a header layout the driver does not parse. `Unsupported FW version` means the file lacks the open-source flag or has a major version the driver does not know. `FW built for incorrect GPU ID` means another BVNC.

Order (updated 2026-10-29): **apercel first** (section 16.10), because it is already proven on a Zero 3W with the same kernel tree and firmware. Then Route L, as a quick comparison of Orange Pi's older driver copy. Both use the vendor's minimal power sequence, so a failure at power, clock or probe points at the board, the DT or the firmware, not at the Android port. If the open drivers boot and Route A doesn't, the difference is in the Android-only writes.

### 16.7 Vendor evidence (checked 2026-10-28)

| What | Where | Key facts |
|---|---|---|
| Orange Pi 6.6 PowerVR driver | `orangepi-xunlong/linux-orangepi` @ `2ac08e8c7cdc28abbdc5c9a9dd812f887ae9c79f` (2026-09-17), `bsp/drivers/gpu/imagination/` | `CONFIG_AW_DRM_POWERVR` (`bsp/drivers/gpu/Kconfig:35`; tristate; selects DRM_EXEC, DRM_GEM_SHMEM_HELPER, DRM_SCHED, DRM_GPUVM, FW_LOADER; GPUVM is built from the driver's own `drm_gpuvm.c`). `dt_match` (`pvr_drv.c:1495`, match table after it): `img,gpu` gets the manual power ops, `thead,th1520-gpu` gets the pwrseq ops. IRQs `IRQGPU` and `IRQGPUDVFS`. Clocks `clk_parent`, `clk`, `clk_bus`, `clk_200` to `clk_800`. Firmware `powervr/rogue_<BVNC>_v1.fw`, v3 header with the open-source flag. No `sunxi_secure_config`, and no write to `0x0a0000b0` or `0x01880014`. DRM name `powervr` (`bsp/drivers/gpu/imagination/pvr_drv.h:10`). |
| Orange Pi 6.6 power domains | same tree: `bsp/drivers/pm_domain/pck600_domains.c`, `bsp/include/dt-bindings/power/sun60iw2-power.h`, `arch/arm64/boot/dts/allwinner/sun60iw2p1.dtsi` | Register block at `id << 12` (`0x1000` per domain). Power control at +0x0, status at +0x8 (`sun60iw2_pck600_pmu`; `STATUS_ON` = `0x8`). GPU_TOP = 5, GPU_CORE = 6. SoC GPU node: `power-domains = <&pd SUN60IW2_PCK_GPU_TOP>` only. The `pd_gpu_core` node is commented out (lines 769–773). |
| Orange Pi 6.6 board DT | `arch/arm64/boot/dts/allwinner/sun60i-a733-orangepi-zero3w.dts` | `&gpu { gpu-supply = <&reg_dcdc4>; }` (line 3421). `reg_dcdc4` is 0.5–1.54 V, always-on and boot-on (line 2141). PMIC `x-powers,axp8191` (line 2099), which the vendor AXP2101 driver accepts (`bsp/drivers/power/mfd/axp2101-i2c.c:91`, `AXP8191_ID`). |
| Orange Pi kernel configs | `orangepi-xunlong/orangepi-build` @ `a95129bf30ea11886cc35f08ebb3e69695a26656`, `external/config/kernel/` | `linux-sun60iw2-current-a733.config` (6.6.98) and `linux-sun60iw2-legacy-a733.config` (5.15.147) both have `# CONFIG_AW_DRM_POWERVR is not set`. The kit's kernel config matches the stock Debian config line for line. |
| Allwinner GPU firmware and userspace | `gitlab.com/tina5.0_aiot/product/linux/external/libgpu` @ `144487e873671ba9817005f08c2abd4756dd4241`: `gpu-firmware/powervr/`, `img-bxm/.../wayland/` | `rogue_36.56.104.183_v1.fw` (126,976 B; sha256 `3974e79f…`; info v3; BVNC 36.56.104.183; open-source flag; fw 1.0 build 6852738). `rgx.fw.36.56.104.183` (sha256 `43eb5d05…`, same as Radxa's; info v2, which the upstream-style driver rejects; not for Route L). `rgx.sh.36.56.104.183` (`71e1b1da…`, same as Radxa's and the kit's). DDK 24.2.6603887 userspace: `libVK_IMG`, `libGLESv2_PVR_MESA`, `libPVROCL`, `libsrv_um`, `libpvr_dri_support`. `libsrv_um` calls `DRM_IOCTL_PVR_SRVKM_INIT`, which the upstream UAPI (`bsp/drivers/gpu/imagination/include/pvr_drm.h`) does not define. `powervr_icd.json` points to `/usr/lib/libVK_IMG.so`. |
| AIoT rogue_km | `gitlab.com/tina5.0_aiot/lichee/bsp` @ `a5fe197076f2fed46223ac911588b4e6e6bffd3c`, `modules/gpu/img-bxm/linux/rogue_km/` | `sunxi_secure_config` in `services/system/rogue/rgx_sunxi/sunxi_platform.c:964`, which writes `0x2` to `0x0a0000b0` and `0x0` to `0x01880014`. `pfnTDSystemSecureConfig` is set in `services/system/rogue/rgx_sunxi/sysconfig.c:371` and called from `services/server/devices/rgxpower.c:886`. `RGX_BVNC := 36.56.104.183` (`build/linux/sunxi_linux/Makefile:69`), and `hwdefs/rogue/km/cores/rgxcore_km_36.56.104.183.h`. |
| Vendor CCU | same Orange Pi tree: `bsp/drivers/clk/sunxi-ng/ccu-sun60iw2.c` | `gpu0_clk` at `0x0B20`: gate bit 31, mux bits 24–26, divider bits 0–3. `gpu0_bus_clk` gate at `0x0B24` bit 0. Reset `RST_BUS_GPU0` = 32 (`bsp/include/dt-bindings/reset/sun60iw2-ccu.h:42`), at `0x0B24` bit 16, which matches our DT. Bit 27 of `0x0B20` is not in the vendor field list. |
| Mainline | `torvalds/linux` master, `drivers/gpu/drm/imagination/pvr_device.c` | `pvr_gpu_support_level`: supported are 33.15.11.3, 36.52.104.182 and 36.53.104.796. Unknown BVNCs are refused unless `exp_hw_support` is set. |
| Mesa (upstream) | `gitlab.freedesktop.org/mesa/mesa` main, `src/imagination/vulkan/pvr_physical_device.c` | Corrected 2026-10-29: the switch there is `pvr_device_is_conformant()` (36.52.104.182, 36.53.104.796 on main/26.3), not the device list. The device info for 36.56.104.183 is in `src/imagination/common/pvr_device_info.c` since 25.3.0 (`1db1038a61a`). Mesa finds the kernel driver by DRM name `powervr` only (`pvr_instance.c`, `winsys/pvr_winsys.c`), with no version or compatible check. Its UAPI header equals mainline's, and the Orange Pi copy's `pvr_drm.h` equals mainline's apart from the include line. |
| apercel | `TumRedSun/apercel`, `mesa/apercel-mesa.patch` (46 files against 26.1.8) | Renames `PVR_DRM_DRIVER_NAME` to `apercel`; marks 36.56.104.183 conformant; raises apiVersion 1.2 → 1.3; enables BDA, 8/16-bit storage, shaderInt8, depthClamp, vertexPipelineStoresAndAtomics, robustImageAccess; raises descriptor/compute/framebuffer limits, adds 2× MSAA; timeline syncobj in the winsys; compiler and load-op-cache changes. Uses `DRM_PVR_BO_CPU_CACHED`, defined nowhere (CheezeCS defines it as 0). |

**Potential upstream commits, from this evidence** (updated 2026-10-29: the K3 people need the same BVNC lines, see 16.8)
- Kernel: one line in `pvr_gpu_support_level()` for 36.56.104.183, as SUPPORTED or EXPERIMENTAL. The firmware carries the device info, so the driver should need no feature table for it. Validate on hardware first. The K3 work will likely send this line first; then our part is a `Tested-by` from the A733.
- Mesa: nothing to add for device support (in since 25.3.0). Conformance (`pvr_device_is_conformant()`) needs a Vulkan CTS run, which Imagination does; BayLibre carries the one-line change (`75ddecf21aa`). apercel's extra features and limits could be upstream candidates one by one, each with tests.
- Device tree: add `allwinner,sun60i-a733-gpu` to the existing `enum: [spacemit,k3-gpu, thead,th1520-gpu]` entry, followed by `img,img-bxm-4-64` and `img,img-rogue` (section 16.3). Upstream has no A733 SoC DTS yet, so the binding patch should go with the GPU node in the A733 dtsi.
- Clocks: the A733 CCU series in review (section 16.3).
- Firmware: Imagination's fw 1.1 for 36.56.104.183 exists in its own linux-firmware fork (section 16.8). Imagination sends it to linux-firmware main, not us. libgpu's 1.0 file is also marked open-source; check its licence before redistributing it.

### 16.8 SpacemiT K3: same GPU, open stack (checked 2026-10-29)

The SpacemiT K3 (RISC-V, `spacemit,x100`) has a PowerVR BXM-4-64 at **BVNC 36.56.104.183**, the same core revision as the A733. Every open-stack piece made for the K3 (firmware, Mesa BVNC support, the kernel support line) also fits the A733. Only the SoC glue differs: clocks, resets, power domains, the DT node.

| Piece | State on 2026-10-29 | Source |
|---|---|---|
| DT binding | `spacemit,k3-gpu` sits in the `img,img-bxm-4-64` enum next to `thead,th1520-gpu`; `spacemit,k1-gpu` is under `img,img-bxe-2-32`. Merged as `16f30811a935` (Baihui Liang, 2026-10-15), on mainline master and linux-next. | `Documentation/devicetree/bindings/gpu/img,powervr-rogue.yaml`; patchwork "add spacemit,k1-gpu and spacemit,k3-gpu" (accepted) |
| Driver support line | 36.56.104.183 is **not** in `pvr_gpu_support_level()` in mainline or linux-next. The July K3 patch "allow probe when no power-domains are described" (v3, 2026-07-28) is superseded: the merged binding requires one power domain for the K3, provided by SpacemiT's APMU driver (pending). | `drivers/gpu/drm/imagination/pvr_device.c`; patchwork |
| `exp_hw_support` | Module parameter of `powervr`. For an unknown BVNC without it, probe fails with "Unknown GPU! Set 'exp_hw_support' to bypass this check." (-ENODEV); with it, the driver warns "Running on unknown hardware; expect issues." and continues. An EXPERIMENTAL entry gives "Unsupported GPU! ..." instead. Use `modprobe powervr exp_hw_support=1` (mainline-based driver or apercel). The Orange Pi 6.6 driver has no BVNC table, so Route L does not need it. | `pvr_device.c` |
| Firmware | Imagination's open-source build for 36.56.104.183 is **fw 1.1 build 6976702**. Not in linux-firmware main (which has 33.15.11.3, 36.52.104.182 and 36.53.104.796 only). It lives in Imagination's fork (gitlab.freedesktop.org/imagination/linux-firmware, `powervr` branch), and BayLibre vendors it. | `src/firmware/imagination-fw-1.1/` (fetch group `fw`) |
| Mesa | Device info for 36.56.104.183 since **25.3.0** (`1db1038a61a`, 2025-10-11); docs list it "in active development". Not conformant, so it needs `PVR_I_WANT_A_BROKEN_VULKAN_DRIVER=1`. PowerVR `VK_EXT_transform_feedback` (`b61ae0073c1`, 2026-10-13, in 26.3.0-rc2) lifts Zink from GLES 2.0 to 3.1. **No Android WSI/AHB for PowerVR upstream**; BayLibre has it (section 16.11). | Mesa clone `1c3a936490f`; `BayLibre/mesa` |
| Android | BayLibre's AOSP **android-17** for the K3 Muse Pico-ITX: upstream `drm/imagination` + fw 1.1 + Mesa ≥ 26.1. Its README says every peripheral is ported and build-green, and **hardware validation is pending the real board**. So it is a reference config, not a proven stack. | `src/baylibre-k3` @ `06c4578e`, `src/baylibre-common` @ `755c243b` |

**Firmware files for BVNC 36.56.104.183.** Both are info v3 with the open-source flag. The `fw_version` fields come from the `pvr_fw_info_header` at `size − 4096`.

| File | Version | Size | sha256 | Where |
|---|---|---|---|---|
| Allwinner libgpu `gpu-firmware/powervr/rogue_36.56.104.183_v1.fw` | 1.0 build 6852738 | 126,976 B | `3974e79f…` | `src/libgpu` (group `ref`); Route L's default |
| Imagination `rogue_36.56.104.183_v1.fw` (via BayLibre `firmware/powervr/`, commit `a09d86fe`) | **1.1 build 6976702** | 131,072 B | `1db1c399c17401d1f79d46c880db81c724d748c784d4639433b076aba2f9c0d2` | `src/firmware/imagination-fw-1.1/` (group `fw`); Route M, and BOARD-DAY step 4c |

Both use the same name and path (`/lib/firmware/powervr/rogue_36.56.104.183_v1.fw`), so only one is installed at a time. The driver prints the one it loaded: `FW version v1.0 (build 6852738 OS)` or `FW version v1.1 (build 6976702 OS)`. The firmware is matched to the GPU core, not the SoC, so the K3 file should boot on the A733. That is a board-day test (BOARD-DAY step 4c), not a fact yet.

**BayLibre's GPU stack** (`src/baylibre-common/device-common.mk`, `src/baylibre-k3/device.mk`). Route M copies this into redroid.
- HALs: `android.hardware.composer.hwc3-service.drm`, `android.hardware.graphics.allocator-service.minigbm`, `mapper.minigbm`.
- Mesa: `libGLES_mesa`, `libGLESv1_CM_mesa`, `libGLESv2_mesa`, `libgallium_dri`, `vulkan.mesa`, `libgbm_mesa`, `dri_gbm`, `vulkan_mesa_icd`, `libgbm_mesa_wrapper`, `zink_dri`, `powervr_dri`. GLES runs on Zink over the PowerVR Vulkan driver.
- Properties: `ro.hardware.egl=mesa`, `ro.hardware.vulkan=mesa`, `debug.hwui.renderer=skiavk`, `debug.renderengine.backend=skiavkthreaded`, `vendor.gralloc.minigbm.backend=gbm_mesa`, `vendor.mesa.gbm_backends_path=/vendor/lib64/gbm`, `ro.hardware.gralloc=minigbm`, `ro.opengles.version=196608` (GLES 3.0).
- `ro.surface_flinger.protected_contents=false`: Mesa PowerVR has no protected memory, and without this SurfaceFlinger aborts.
- `/dev/pvr_sync 0660 system graphics` in `ueventd.k3.rc`.
- The firmware is copied to `/vendor/firmware/powervr/`. In redroid the host kernel loads firmware from the host's `/lib/firmware`, so this line does not carry over.
- The Mesa prebuilts are riscv64. For the A733, rebuild Mesa for arm64.

**Route M plan** (after apercel or Route L passes on the board; the detailed port is section 16.11):
1. Host: keep Route L's `powervr.ko` (or apercel, or a mainline-based build with `exp_hw_support=1`). Try both firmware files (BOARD-DAY 4b and 4c) and keep the one that boots.
2. Host Mesa ≥ 26.3: `vulkaninfo --summary` with `PVR_I_WANT_A_BROKEN_VULKAN_DRIVER=1`. Unpatched for Route L's driver (DRM name `powervr`); with apercel's 26.3 patch for apercel (DRM name `apercel`).
3. redroid: build Mesa (imagination Vulkan + Zink, BayLibre's Android commits on 26.3) for arm64 Android 13 and swap it into the image as an overlay. Keep redroid's gbm_gralloc and fake composer first; BayLibre's minigbm `gbm_mesa` and hwc3 drm are not needed for redroid (section 16.11). Pass `/dev/dri/renderD128` into the container.
4. Check `dumpsys SurfaceFlinger` for the GLES/Vulkan renderer strings, then run the two apps.
- Risks: the Vulkan driver is non-conformant; GLES-on-Zink overhead; Android 13 vs BayLibre's Android 17 HAL versions (hwc3 and minigbm AIDL exist on 13, but check the versions); and the BayLibre stack is not hardware-validated.

**What the YouTube comments (2026-10) claimed, checked:**
- "Only a proprietary driver exists": false. Upstream `drm/imagination` + Mesa cover this BVNC as work in progress, Imagination ships open firmware for it, and BayLibre builds a fully open Android with it.
- "René Rebe is working on BXM-4-64 on the K3": unconfirmed. The K3 binding is by Baihui Liang, and the Android stack is BayLibre's. We found nothing by René Rebe.
- "Mainlined in Linux 7.3 or 7.5, in linux-next": only partly true. The K3 binding is on master (for 7.4). The BVNC support line is in neither mainline nor linux-next, and nothing A733-specific for the GPU has been posted.
- "Using the GPU on 6.6.98-2-aw2511": plausible on the vendor BSP kernel, the same 6.6.98 base as Route L and apercel. It is not mainline.

**Upstream contribution ideas, refined:**
1. `Tested-by` on the K3 BVNC support line when it is posted, run on the Zero 3W.
2. An A733 GPU node and compatible once the A733 dtsi and CCU land (section 16.3).
3. A Mesa A733 test report, if the K3 entry lands first.

### 16.9 Keep checking: `scripts/60-mainline-watch.py`

Run from the farm folder on any PC with internet (Python 3, stdlib only):

```sh
python3 -I scripts/60-mainline-watch.py
```

It prints one line per check, marks changes since the last saved run with `*`, and lists new patchwork hits as `NEW`. It saves `out/mainline-watch/<date>.json`. `out/` is git-ignored, so the first run on a new PC has no baseline, and every value prints as unchanged. Compare by hand against the table below.

| Check | Source | Baseline 2026-10-29 |
|---|---|---|
| `sun60i` DTS files | cgit `arch/arm64/boot/dts/allwinner`, mainline + next | none |
| A733 CCU driver | cgit `drivers/clk/sunxi-ng` | none |
| drm/imagination supported BVNCs | `pvr_device.c`, `pvr_gpu_support_level` | 33.15.11.3, 36.52.104.182, 36.53.104.796 |
| 36.56.104.183 in driver | same file | no |
| GPU binding allwinner / k3 | `img,powervr-rogue.yaml` | `spacemit,k1-gpu`, `spacemit,k3-gpu` (no Allwinner) |
| AXP318W in `axp20x.c` | `drivers/mfd/axp20x.c` | no |
| A733 in `sunxi-mmc.c` | `drivers/mmc/host/sunxi-mmc.c` | no |
| linux-firmware `powervr/` | gitlab.com API, main | `rogue_33.15.11.3_v1.fw`, `rogue_36.52.104.182_v1.fw`, `rogue_36.53.104.796_v1.fw` |
| Mesa docs, 36.56.104.183 | docs.mesa3d.org PowerVR page | listed, table "in active development" |
| Mesa newest release | docs.mesa3d.org release notes | 26.2.6 (26.3 = GLES 3.1 via Zink is still at rc; CheezeCS uses 26.3.0-rc2) |
| Community repo heads, apercel issues | GitHub API | TumRedSun/apercel `e098b9f1ae16` (2026-10-20), CheezeCS/apercel `d03675d4a38e` (2026-10-25), armbian-a733-gpu `6960be508179` (2026-10-25), bobyshamen-arch/pvr-a733 `60a60f43dc56` (2026-10-10), ayiejosh/a733-powervr-fex `0eb8099bf8b5` (2026-10-27), BayLibre/mesa `android-17-pvr-support` `92f674847202` (2026-10-03); one apercel issue (#1, the Zero 3W report) |
| U-Boot `mach-sunxi` | GitHub API, master | no sun60i / a733 files |
| patchwork `a733`, `axp318`, `sun60i`, `k3-gpu`, `36.56.104`, `drm/imagination` | patchwork.kernel.org API, newest 6 | A733 UART v2 (handled-elsewhere, 2026-10-19), A733 pinctrl I/O-voltage fixes (new, 2026-10-12/13), CCU v6 (2026-10-09), AXP318W v8 (2026-09-10), K3 GPU binding (accepted, 2026-10-15), no `36.56.104` hits; drm/imagination: FW-info query v4 and META/RISC-V firmware-header rework (2026-10-28) |

What to watch for, in order of value to us:
1. **36.56.104.183 in `pvr_gpu_support_level`** (driver patch, probably from the K3 side): Route M then needs no `exp_hw_support`.
2. **Mesa 26.3.0 released**: GLES 3.1 through Zink, the floor for Android (section 16.10). Rebase the apercel Mesa patch from rc2.
3. **`rogue_36.56.104.183_v1.fw` in linux-firmware main**: distros then ship the firmware.
4. **AXP318W in `axp20x.c`** and **the A733 CCU**: the prerequisites for any mainline A733 board.
5. **A `sun60i` DTS**: the start of a mainline Zero 3W DTS.

Not covered by the script: lore.kernel.org and gitlab.freedesktop.org (both block scripts with a bot check). Check Mesa main's `pvr_physical_device.c` and Imagination's linux-firmware fork in a browser.


### 16.10 Already proven on a Zero 3W: apercel + Imagination fw 1.1 (checked 2026-10-29)

On 2026-10-25 a user (CheezeCS) reported the open stack **working on an Orange Pi Zero 3W** (4 GB) in apercel issue #1. The report and fork were made with AI help, so treat them as one tester's results, not as review.

| Item | Their result |
|---|---|
| Kernel | Armbian trixie, Orange Pi vendor kernel `6.6.98-sun60iw2`: the same tree as ours |
| Driver | apercel `e098b9f` + **30 backported upstream drm/imagination fixes** (soft-reset deadlock `a55c2a5c8d68`, paired geometry/fragment jobs, timeouts, context-reset handling, page-table preallocation OOM `789f290b2e81`, remap ref leak `196d4d10c1b3`, …), fork `CheezeCS/apercel` @ `d03675d4a38e` |
| Firmware | `1.1.OS@6976702`, sha256 `1db1c399…`: **the same file as our fetch group `fw`**. Loads with `FW version v1.1 (build 6976702 OS)`. |
| GPU | probes, runs at 1008 MHz |
| Vulkan | 1.3 device, compute (`vktest`), WSI (`vkcube` on Wayland), Mesa 26.1.8 and 26.3.0-rc2 |
| GL through Zink | Mesa 26.1.8: GL 2.1 / **GLES 2.0 only**. Mesa **26.3**: GL 3.2 core / **GLES 3.1**, because 26.3 adds `VK_EXT_transform_feedback` for PowerVR (mesa!44385, enabled for 36.56.104.183) |
| Apps | sway, vkcube, Electron 45 / Vesktop with GPU compositing and WebGL2 (26.3); KDE Plasma smooth at 1080p, slow at 3440×1440 |
| Not tested | suspend/resume, long-running stability, conformance |

**What it changes for us:**
1. **Steps 1–2 of the GPU work are done once on this board model.** Power-on, firmware boot and host Vulkan already work on a Zero 3W, with the firmware we fetch. Our board still has to repeat them with our kernel, but the risk is now low.
2. **Mesa ≥ 26.3 is the floor for Route M.** Android apps need GLES 3.0; Zink on Mesa 26.1 stops at GLES 2.0. Chromium 152 no longer falls back to ES 2.0 (CheezeCS); Android WebView is Chromium too, so expect the same there.
3. **Host driver: apercel first, Route L second.** Orange Pi's own driver copy (Route L) matches upstream **≈ v6.18** (file diff against v6.14…v7.3 and master; closest to v6.18 in `pvr_fw.c`, `pvr_drv.c`, `pvr_power.c` and `pvr_device.c`; it has RISC-V firmware support and no BVNC gate). So it lacks all fixes from 2025-12 on. Checked: its `pvr_power_reset()` still calls `disable_irq()` on a soft reset, the deadlock that `a55c2a5c8d68` fixes. CheezeCS's apercel carries those fixes and is proven on the Zero 3W. Route L stays as a cheap comparison (its modules are already built).
4. **Firmware 1.1 should also run on Route L.** The firmware interface headers (`pvr_rogue_fwif*.h`) are the same from v6.18 to master apart from `reset_reason` changing from an enum to `u32` (same size) and new reset-reason values (v7.1). Both drivers accept any major-1 header.
5. **apercel's DRM driver name is `apercel`, not `powervr`.** Mesa finds the device by name only, so with apercel Mesa needs apercel's patch (`PVR_DRM_DRIVER_NAME`); without it `vulkaninfo` silently finds nothing. The reverse holds for Route L and mainline (`powervr`): use Mesa without that rename. Mesa ≥ 25.3 already knows 36.56.104.183, so the only other thing apercel's patch changes for us is extra features and limits. Check with `strings libvulkan_powervr_mesa.so | grep -x apercel`. The same applies inside redroid (Route M).
6. **apercel's firmware path is `/lib/firmware/apercel/rogue_36.56.104.183_v1.fw`**, not `powervr/`.
7. **Don't install apercel's `conf/99-apercel.conf` on a farm board.** It blacklists `pvrsrvkm`, which Route A needs. Load apercel by hand for the test (`softdep` order: `gpu_sched`, `drm_exec`, `drm_shmem_helper`; apercel option `no_autosuspend=1`).
8. **Helper modules.** `DRM_SCHED`, `DRM_EXEC` and `DRM_GEM_SHMEM_HELPER` are prompt-less tristates in the Orange Pi tree, off in our config. `scripts/22-build-apercel.sh` builds them as external modules from the tree's own sources, then apercel. **Built on 2026-10-29** against our kernel tree: all four modules have vermagic `6.6.98-sun60iw2-redroid SMP preempt mod_unload aarch64`; no unresolved symbols; no export clashes with vmlinux (apercel's own GPUVM copy exports `*_img` names, while vmlinux exports the old 6.6 `drm_gpuva_*` API). `apercel.ko` sha256 `f496a182…` (all hashes in `out/apercel/SHA256SUMS`). The A733 code path is compiled in (`CONFIG_ARCH_SUN60IW2=y`). The BTF-mismatch load failure CheezeCS hit does not apply to us: our config has `CONFIG_DEBUG_INFO_BTF` off.
9. **GPU IRQ.** apercel's boot hook pins `IRQGPU` to the last big core (cpu7). In our farm layout cpu7 belongs to instance 2 and cpu0 takes host IRQs (section 8.1). Measure both placements on the board before choosing.

**Upstream notes found on the way:**
- The merged K3 binding puts the K3 in the TH1520 group: **one** unified power domain (required) and one clock. The A733 has two GPU clocks (module clock + bus gate) and two PCK-600 GPU domains (GPU_TOP, GPU_CORE; the vendor DT and apercel use GPU_TOP only). So an A733 entry needs its own constraints. The board-day PD readbacks (BOARD-DAY 4b) tell whether one domain is enough.
- Imagination is active upstream: "Support for querying Firmware information" v4 (2026-10-28) adds `DRM_PVR_DEV_QUERY_FW_INFO_GET`, so Mesa can detect firmware fixes by major.minor. Prefer fw 1.1, and expect future Mesa to use this query (older drivers will need the patch or a fallback).
- Imagination promoted 36.52.104.182 (TH1520) to supported in 7.3 only after Mesa conformance. 36.56.104.183 will likely follow the same path: experimental, then supported.

### 16.11 Route M inside redroid 13: what the userspace port needs (researched 2026-10-29)

How redroid 13 does host-GPU mode today (image `13.0.0_64only-240527`, checked in the extracted image under `out/cache/` and on GitHub):

| Piece | redroid 13 today | Route M needs |
|---|---|---|
| Mesa | Prebuilt binaries, Mesa 24.0.8 (`git-441f064c1c`, source unpublished), cross-built with the NDK, from `remote-android/device_redroid-prebuilts` `7bd6c5fb7e`. AOSP's `external/mesa3d` is removed from the manifest. Drivers: panfrost, lima, freedreno, etnaviv, v3d, vc4, virgl, zink, …; **no imagination**. | Mesa ≥ 26.3 with PowerVR Vulkan + Zink, built for Android arm64 |
| PowerVR on Android | — | Upstream Mesa (27.0-devel, 2026-10-29) still has **no Android WSI / AHardwareBuffer for PowerVR** and no 36.56.104.183 entry. BayLibre's branch has both: `BayLibre/mesa` `android-17-pvr-support` (`92f6748472`): `583ce30933` "imagination/vulkan: add Android platform support", `20d0394648` kopper on Android, `d14b83e8e9` Zink device choice, `75ddecf21a` BXM-4-64 incl. 36.56.104.183 marked conformant (so no `PVR_I_WANT_A_BROKEN_VULKAN_DRIVER`, which an Android property could not carry anyway). |
| GPU selection | `gpu_config.sh` (from `vendor_redroid`): render-node allowlist: i915, amdgpu, nouveau, virtio_gpu, v3d, vc4, msm_drm, panfrost; then `ro.hardware.vulkan` by driver name | Add a `powervr` / `apercel` case: `ro.hardware.egl=mesa`, `ro.hardware.vulkan=mesa`, `gralloc.gbm.device`, Zink as the GL driver (`mesa.loader.driver.override=zink`, property-key length unverified). Or pass `androidboot.redroid_gpu_node=/dev/dri/renderD128`. |
| Gralloc | `gralloc.gbm.so` (gbm_gralloc, `remote-android/gbm_gralloc` `a8874a18ad78`) via allocator 2.0 / mapper 2.1 | Keep it first: it only needs `libgbm.so.1` and a render node. minigbm `gbm_mesa` (BayLibre's choice) is not in AOSP minigbm on any branch; it is GloDroid's patch series (`glodroid_device` `patches/vendor/minigbm/0001–0013`, ran on Android 13 r11), and on 13 it needs a mapper 4 build + VINTF edits = a vendor rebuild. |
| Composer | `hwcomposer.redroid.so` (HWC1 via `hwc2on1adapter`): a fake display, every layer composited by RenderEngine | Keep it. BayLibre's hwc3 drm composer needs a KMS device; the GPU node is render-only. |
| SurfaceFlinger | RenderEngine on GLES (`debug.renderengine.backend=gles`). **Android 13 RenderEngine has no Vulkan backend.** | So on redroid 13, composition runs on Zink GLES. Android 14+ RenderEngine has Skia-Vulkan (`skiavk`), which BayLibre uses. |

**Overlay first, like redroid ships its own Mesa.** A Dockerfile on top of the stock image can replace the Mesa files: `/vendor/lib64/egl/lib{EGL,GLESv1_CM,GLESv2}_mesa.so`, `/vendor/lib64/dri/*` (new gallium + `zink_dri.so`, drop the old symlinks), `/vendor/lib64/libgbm.so.1`, `/vendor/lib64/gbm/dri_gbm.so`, `/vendor/lib64/hw/vulkan.mesa.so` (SONAME fixed with `patchelf`), and a newer `libdrm.so.2`. Constraints from the image's VNDK lists: the libraries load in the `sphal` namespace, so they may only depend on LLNDK/VNDK-SP libraries and `/vendor/lib64`. Build without expat, link `-static-libstdc++`, and keep `platform-sdk-version` at 33. redroid has SELinux off, so no sepolicy work.

**Decision to make before porting: which redroid base for Route M.** Route A is tied to redroid 13 (the Android 13 DDK blobs). Route M is not. On redroid 14+ SurfaceFlinger and hwui can use Vulkan directly (`skiavk`) instead of Zink, closer to BayLibre's tested config. The cost is a new base image and re-checking binderfs, CPU and memory sizing.

**Prior art:** none for PowerVR in redroid. `bizkut/redroid-mesa26` (2026-10-20) builds Mesa 26.2.5 inside AOSP for redroid 14 on AMD x86_64 (probe-level tests only). redroid issue #739 (Mesa upgrade) is open since 2024. RK3588 users run Mali blobs in redroid. No published Zink-in-redroid performance data was found.

**Mesa for Android arm64: start from BayLibre, rebase onto 26.3.**
- Branches in `BayLibre/mesa`: `android-17-pvr-support` (tip `92f67484720`, 2026-10-03, 35 commits on Mesa main `82b868960e0` of 2026-09-23) and `android-17-pvr-perf` (`f0cabdd9b56`, the same plus about 65 compiler/driver performance commits). The K3 prebuilts are riscv64 (`device/spacemit/k1/mesa`, built with `build-mesa-powervr.sh --board=k3`), so we must build our own.
- The branch already has an **arm64 build path** (Kha Tran: `fcb2e279663`, `2fe6e0210fc`, `573f4a1073d` `--build-arm64` / `android-aarch64` cross file, NDK r29, API 35, vndk-v35 stubs). Its options: `-Dplatforms=android -Dandroid-stub=false -Dgallium-drivers=zink -Dvulkan-drivers=imagination -Dgbm=enabled -Degl=enabled -Dimagination-srv=true -Dllvm=disabled -Dmesa-clc=system -Dprecomp-compiler=system -Dallow-fallback-for=libdrm,perfetto -Dgbm-backends-path=/vendor/lib64/gbm -Dplatform-sdk-version=35`. It needs host tools from a first host build (`mesa_clc`, `vtn_bindgen2`, `pdsc_precomp`: `-Dinstall-mesa-clc=true -Dinstall-precomp-compiler=true`).
- **Gap found:** the branch base (2026-09-23) predates PowerVR transform feedback (`b61ae0073c1`, 2026-10-13, in 26.3.0-rc2; checked with `git merge-base`). So BayLibre's Mesa gives Zink no GLES 3.x path. For apps we need their Android commits rebased onto 26.3: `583ce30933e` (Android WSI/AHB for PowerVR), `20d03946484` (kopper on Android), `d14b83e8e97` (Zink device fallback), `b6ff534c8f2` (gralloc stride of imported AHB), `9a0a0d882fd`/`842812d75af` (BO cache; without it SuperTuxKart ran at about 6 fps on the K3), `75ddecf21aa` (conformant flag), plus the image/format fixes. If the host driver is apercel, add the driver-name change from CheezeCS's 26.3 patch.
- For Android 13 (API 33): `-Dplatform-sdk-version=33`, NDK `aarch64-linux-android33-clang`. IMapper5 needs SDK ≥ 35, so on 13 Mesa uses mapper4 (vendor build) or the `android-stub` path (gralloc via cros_api/libdrm/fallback, which is what redroid's gbm_gralloc offers). BayLibre's vndk-v35 stubs may expose symbols Android 13 lacks: link against stubs from the redroid-13 image instead (untested).

**Route M work list, in order** (none of it needs the board until step 4; steps 1–3 done 2026-10-29, section 16.13):
1. Host build of Mesa 26.3 tools, then the rebased BayLibre branch for Android arm64 / API 33, on the build PC.
2. Overlay image on `redroid/redroid:13.0.0_64only-240527` with the Mesa files listed above and a `powervr`/`apercel` case in `gpu_config.sh`.
3. Static checks like scripts 25/26: every `NEEDED` library resolvable in the `sphal` namespace.
4. Board: apercel or Route L on the host, then the overlay container. Look at `dumpsys SurfaceFlinger` (GLES renderer = Zink on PowerVR), then the apps.
5. If gbm_gralloc + Zink allocation fails: the vendor rebuild (GloDroid minigbm patches, mapper 4, VINTF), or move Route M to redroid 14+.

### 16.12 More A733 GPU work in the community, and what it means for Routes A and M (checked 2026-10-29)

A GitHub search for A733 GPU projects found several more boards and stacks besides CheezeCS (section 16.10):

| Repo (last commit) | Board | Stack | Key findings |
|---|---|---|---|
| `ayiejosh/a733-powervr-fex` (`trixie`, 2026-10-27) | Radxa Cubie A7A/A7S, Debian 13, 6.6 BSP | Vendor Linux DDK (`img-bxm-dkms` from Radxa) + their PRIME-import patch, Mesa/Zink on `libVK_IMG`, FEX, DXVK | Off-screen GPU (Vulkan, D3D9–11, Zink) works. **A live GPU compositor through `pvrsrvkm` deadlocks the kernel** (`mutex_spin_on_owner` in IRQ, power cycle needed). The same class of hang comes from `scrot` while a GPU app runs and from `DXVK_HUD`. Overlays: GPU 600 → 1104 MHz, DSU/L3 780 → 1027 MHz (`dramread` +38%). |
| `Haidegger22/opi-zero3w-gpu-tuning` (2026-10-19) | **Orange Pi Zero 3W**, Debian 13, `6.6.98-sun60iw2` | Vendor Linux DDK + PRIME patch | Vendor `pvrsrvkm` works on the Zero 3W (GLES, Vulkan 1.3, Chromium/ANGLE). apercel worked too (Vulkan 1.3) but only off-screen under X11. **Unloading or reloading `pvrsrvkm` on a live GPU hangs the board.** glmark2-es2 522 → 602 with the overlays. |
| `davidhfrankelcodes/pvr-a733-armbian` (2026-10-01) | **Orange Pi Zero 3W**, Armbian | Same vendor recipe | `clpeak` about 35 GFLOPS fp32. Same compositor deadlock. The closed Linux driver runs at 600 MHz unless the DT has `clk_rate`; a 1008 MHz overlay scales throughput about 1:1. |
| `bobyshamen-arch/pvr-a733` (2026-10-10) | Radxa Cubie A7A, Armbian, `6.6.98-vendor-sun60iw2` | **drm/imagination from Linux 7.3-rc6** backported to 6.6, `exp_hw_support=1`, **unmodified Mesa main** | Runtime suspend/resume, firmware resets on faults, 200–1008 MHz (`a733_clk_mhz`). Its DRM name stays `powervr`, so stock Mesa works. Compute only; display not tested. |
| `nickyg666/orangepi-zero3w-mainline` (2026-08-18) | **Orange Pi Zero 3W** | Linux 6.18.19 + vendor BSP drivers merged | Boots with vendor CCU/pinctrl/UART; patched DT for mainline `sunxi-mmc`; notes that mainline has no AXP8191 (= AXP318W, section 16.5) driver. No GPU. |

**Mainline also has an A733 GPU result.** Commit `b462a227d854` ("pmdomain: sunxi: support power domain flags for pck600", Yuanshen Cao, 2026-05-10) marks the A733 **GPU_CORE domain as always-on** in the mainline PCK-600 driver. The commit message says this was needed "while bringing up the PowerVR GPU on the A733 (Radxa Cubie A7Z)", that the GPU then worked, and thanks Icenowy. So:
- A mainline A733 GPU node needs only GPU_TOP: the single-power-domain group of the binding (with the K3 and TH1520) fits. Only the clock count differs (the A733 has a module clock and a bus gate).
- In our vendor DT, `pd_gpu_core@6` is absent from the power controller (checked in the decompiled Zero 3W DTB), so the vendor kernel never touches PD 6. It stays as the boot code left it, and the Android driver's manual PPU write turns it on.

**DT check for apercel (done here):** the Zero 3W DTB's `gpu@1800000` (`img,gpu`) provides everything apercel requests:
- clocks `clk_parent`, `clk`, `clk_bus`, `clk_800`…`clk_200`;
- interrupts `IRQGPU` and `IRQGPUDVFS`;
- one reset;
- `power-domains = <&pd 5>`;
- OPP table 400/600/800/1008 MHz at 800/800/840/960 mV;
- `gpu-supply` = AXP8191 `dcdc4` (always-on);
- a `gpu_thermal_zone`.

**What this changes for us:**
1. **Route A risk: the compositor deadlock.** It was seen with the Linux-flavour DDK 6603887 when a compositor scans out to HDMI. redroid has no scanout (SurfaceFlinger renders into buffers that the fake composer hands on), and our DDK is the Android flavour 6643903. So the trigger may be absent, but the "CPU reads a GPU buffer while the GPU renders" case (`scrot`) has an equivalent in `screencap` and scrcpy. On board day, keep the serial console attached during step 7, and take a screenshot while an app animates.
2. **Never `rmmod` or reload `pvrsrvkm` on a live GPU**, and reboot after the open-driver tests before step 5 (BOARD-DAY).
3. **The secure-reset patch may be unnecessary.** Radxa's Linux DDK, which has no secure writes, runs on the Zero 3W. So a fallback without our port is now built here: `SECURE_CONFIG=0 ./scripts/20-build-pvrsrvkm-android.sh` writes `out/deploy/lib/modules/pvrsrvkm-android-nosecure.ko` (vermagic `6.6.98-sun60iw2-redroid`; the build tree has no patch marker, while the main tree has one). Use it if Route A hangs at GPU start.
4. **GPU clock in Route A:** our Android DDK build has `SUPPORT_LINUX_DVFS`, so `sunxi_get_opp()` sets the start clock to the top OPP (1008 MHz) instead of the 600 MHz default that the Linux DKMS build falls back to. Check `dmesg` for `change default clk_rate to max opp freq`.
5. **DSU at 780 MHz is a farm bottleneck to test later.** The vendor kernel has no DSU frequency driver. The overlay that raises it to 1027 MHz gave +38% DRAM read in their tests. Two Android instances are memory-bound, so measure it once the farm runs, with stability tests.
6. **A second open driver for Route M:** `bobyshamen-arch/pvr-a733` is newer upstream code (7.3-rc6) and keeps the `powervr` DRM name, so stock Mesa plus BayLibre's Android commits would need no driver-name patch. Compare it with apercel (more backported fixes, proven on the Zero 3W) before choosing.

### 16.13 Route M userspace built: Mesa 26.3 PowerVR + Zink for redroid 13 (2026-10-29)

Steps 1–3 of the Route M work list (section 16.11) are done on this PC. Steps 4–5 need the board.

**What was built** (`scripts/23-build-mesa-android.sh`, about 8 GB under `out/` and `src/`):
- **Source:** upstream Mesa `26.3` branch at `07f74f00104` (26.3.0-rc2+89, 2026-10-27). On top of it, BayLibre's 34 `android-17-pvr-support` commits are cherry-picked (`92f67484720`; only the riscv64 cross-file tweak `992647d02ea` is skipped).
  - One conflict: the PowerVR extension list. It is resolved with `-X ours` for that commit, because 26.3 already lists `EXT_image_drm_format_modifier`. The script reproduces the exact same tree (checked in a separate worktree).
  - Plus `config/mesa-pvr-accept-apercel-drm-name.patch`. Mesa binds to both DRM names, `powervr` (Route L, mainline-based drivers) and `apercel`, and the pipe loader maps both to Zink. Upstream already did that mapping for `powervr`.
  - The patch is labelled `Generated-by: LLM` and left uncommitted in the Mesa tree, as Mesa's `AGENTS.md` asks.
- **Toolchains:**
  - Host tools (`mesa_clc`, `vtn_bindgen2`, `pco_clc`, `pdsc_precomp`) come from a conda-forge env with LLVM/clang 19.1.7, SPIRV-LLVM-Translator 19.1.13, SPIRV-Tools 2026.4 and meson 1.12.1 (`micromamba`, `out/toolchains/mesa-host`). Ubuntu 22.04 only has LLVM 14, and Mesa's CLC needs ≥ 15.
  - Target: NDK r29 (SHA-1 `87e2bb7e…` checked against Google's repository XML), `aarch64-linux-android33`, with BayLibre's vndk stubs.
  - Cross file: `config/mesa-android-aarch64-api33.ini` (BayLibre's arm64 file with API 33).
- **Options:**
  - Drivers and APIs: `-Dplatforms=android -Dplatform-sdk-version=33 -Dvulkan-drivers=imagination -Dgallium-drivers=zink -Dgbm=enabled -Degl=enabled -Dllvm=disabled`.
  - Host tools and libdrm: `-Dmesa-clc=system -Dprecomp-compiler=system -Dallow-fallback-for=libdrm,perfetto`.
  - Android: `-Dandroid-stub=false -Dandroid-strict=true -Dgbm-backends-path=/vendor/lib64/gbm`.
- **Two variants:**
  - `base`: as above.
  - `VARIANT=apercel`: also CheezeCS's `apercel-mesa-26.3.0-rc2.patch` (Vulkan 1.3 features and limits, pco compiler changes, load-op caches). That combination gave GLES 3.1 through Zink on a Zero 3W. It is applied in its own worktree `src/mesa-apercel`, with its own host tools, because the patch changes the pco compiler. Apercel's duplicate conformance case is dropped, and its driver rename is replaced by the accept-both patch.

**Checks done without a board:**
- **Contents.** `vulkan.mesa.so` exports `HMI` (the Android Vulkan HAL entry) and carries `VK_ANDROID_native_buffer`, `vkGetAndroidHardwareBufferPropertiesANDROID`, `vkGetSwapchainGrallocUsage2ANDROID` and `VK_EXT_transform_feedback`. 36.56.104.183 is in the conformance list, so no `PVR_I_WANT_A_BROKEN_VULKAN_DRIVER`. Both DRM names are compiled in. `libgallium_dri.so` contains Zink. The version string is `Mesa 26.3.0-rc2 (git-e5f982d0e2)`.
- **Linking against redroid 13.** `scripts/32-make-redroid-mesa-context.sh` packages the overlay and runs the same namespace-aware link check as script 26 against the stock `redroid/redroid:13.0.0_64only-240527` image.
  - Covered: `libEGL_mesa.so`, `libGLESv1_CM_mesa.so`, `libGLESv2_mesa.so`, `vulkan.mesa.so` and `dri_gbm.so`, plus redroid's own `gralloc.gbm.so` on our `libgbm.so.1`.
  - **0 problems in both variants.** Every `DT_NEEDED` resolves inside the sphal namespace (LLNDK, VNDK-SP, `/vendor/lib64`), and 261–458 imports per entry point resolve with matching symbol versions. That includes `libc++.so` from Android 13's VNDK-SP and mapper@4.0.
  - Two fixes were needed to get there. redroid ships `libdrm.so.2` (Mesa's own 2.4.120), not AOSP's `libdrm.so`, so every library's `NEEDED libdrm.so` is rewritten with `patchelf`. And `libgbm` is renamed to `libgbm.so.1`, the name gbm_gralloc needs.

**The overlay** (`out/redroid-mesa/`, 30 MB; `out/redroid-mesa-apercel/` for the variant) uses the same file names as redroid's own host-GPU Mesa, so redroid's gbm_gralloc and fake composer stay:
- `vendor/lib64/egl/lib{EGL,GLESv1_CM,GLESv2}_mesa.so`
- `vendor/lib64/libgallium_dri.so`
- `vendor/lib64/libgbm.so.1`
- `vendor/lib64/gbm/dri_gbm.so`
- `vendor/lib64/hw/vulkan.mesa.so`
- `vendor/bin/gpu_config.sh`: a `powervr`/`apercel` case that sets `ro.hardware.egl=mesa`, `ro.hardware.gralloc=gbm`, `ro.hardware.vulkan=mesa`, `gralloc.gbm.device=/dev/dri/renderD<n>` and `vendor.mesa.loader.driver.override=zink`. Otherwise it falls back to redroid's script, kept as `gpu_config.orig.sh`.
- `vendor/etc/init/redroid.common.rc` with `ro.opengles.version` lowered from 3.2 to 3.1, the level Zink reaches here (section 16.14).
- The Dockerfile is COPY-only. Build it on the board with `docker build -t redroid-mesa:13 out/redroid-mesa`. Mesa 26 reads `vendor.mesa.*` properties with keys up to 128 characters, so the property route works for Mesa options.

**Not known until the board runs it:** whether the PowerVR Android WSI works inside redroid with gbm_gralloc buffers (BayLibre ran it with minigbm `gbm_mesa`); SurfaceFlinger on Zink GLES (Android 13 RenderEngine has no Vulkan path); and performance. BOARD-DAY step 8 is the first try.

### 16.14 Route M checked without a board: the PowerVR drm-shim (2026-10-29)

Mesa ships a no-op DRM shim for PowerVR (`src/imagination/drm-shim`). Preloaded, it fakes a `powervr` render node, and `PVR_SHIM_DEVICE_BVNC=36.56.104.183` makes it report our GPU. `scripts/24-mesa-shim-probe.sh` builds our exact Mesa tree for x86 with the shim, Zink and surfaceless EGL. It then runs `vulkaninfo` and `scripts/mesa_glver.c`, which tries GLES and desktop GL contexts from the top version down. The feature, limit and version queries are the real driver code; nothing executes on a GPU.

How it was made to work: the shim hooks `stat()`/`readdir()`, but conda's libdrm calls `__xstat` (built against old glibc headers), which the shim doesn't hook on glibc ≥ 2.33. So the script builds libdrm 2.4.129 with the system compiler (`out/toolchains/libdrm-sys`). The variant is built with `-Db_ndebug=true`, see the assertion below.

| | base | apercel variant |
|---|---|---|
| Vulkan device | `PowerVR B-Series BXM-4-64 MC1`, **Vulkan 1.2**, `Mesa 26.3.0-rc2 (git-e5f982d0e2)` | **Vulkan 1.3** |
| GLES through Zink | **OpenGL ES 3.1** (GLSL ES 3.10); 3.2 refused | the same: **ES 3.1** |
| Desktop GL through Zink | **3.2 core** (GLSL 1.50); 3.3 refused | the same: **3.2 core** |
| Features the variant adds | — | depthClamp, vertexPipelineStoresAndAtomics, bufferDeviceAddress, 8/16-bit storage and push constants, shaderInt8, robustImageAccess, shaderZeroInitializeWorkgroupMemory, pipelineCreationCacheControl |
| Missing in both | geometryShader, tessellationShader, dualSrcBlend, fillModeNonSolid, textureCompressionBC, pipelineStatisticsQuery | |

So **the base build already reaches GLES 3.1**, the same as CheezeCS measured with apercel's patch on real hardware. The variant adds only Vulkan 1.3 features. The overlay now advertises `ro.opengles.version` = 3.1.

**The variant trips a Mesa assertion.** Built with asserts on, every Vulkan start in the apercel variant aborts in `vk_device.c` `get_timeline_mode()` ("We can only have one timeline mode").
- apercel's winsys adds an emulated timeline sync type next to the DRM syncobj type. That type is already timeline-capable whenever the kernel has `DRIVER_SYNCOBJ_TIMELINE`, which both the apercel and the Orange Pi kernel drivers set (`pvr_drv.c`), and the shim reports it too.
- Release builds skip the assert and pick the emulated timeline. That probably works, but it is a configuration upstream Mesa forbids.
- **Prefer the base variant for Route M.** Use the apercel variant only to compare.

**Other Android-relevant facts** (base build):
- **GLES 3.1 extensions (134):**
  - Present: `GL_OES_EGL_image`, `GL_OES_EGL_image_external` and `_essl3` (video and camera textures), `GL_EXT_texture_format_BGRA8888`, `GL_KHR_texture_compression_astc_ldr`, `GL_OES_compressed_ETC1_RGB8_texture`, `GL_EXT_color_buffer_float` and `_half_float`, `GL_EXT_texture_filter_anisotropic`, `GL_EXT_buffer_storage`, `GL_KHR_debug`.
  - Missing: `GL_EXT_YUV_target`, `GL_OES_texture_float_linear`, and the geometry, tessellation and AEP extensions.
- **Vulkan:** `samplerYcbcrConversion` is true. The PowerVR driver offers only `DRM_FORMAT_MOD_LINEAR`, so every buffer shared through gralloc is linear.
- **gralloc fit:**
  - Mesa's `u_gralloc` tries CROS, then IMapper4 (redroid has no mapper 4 service), then the libdrm backend. That backend accepts gralloc modules named `GBM Memory Allocator`, which is the name in redroid's `gralloc.gbm.so`. It reads libdrm's `gralloc_handle_t`, the one `remote-android/gbm_gralloc` (`a8874a18ad78`) uses, including the `modifier` field.
  - gbm_gralloc allocates with `gbm_bo_create()` on our `libgbm.so.1`: `dri_gbm` → Zink → PowerVR. CPU-access buffers get `GBM_BO_USE_LINEAR`.
- **redroid 16 has the same GPU stack.** `redroid/redroid:16.0.0_64only-250627` (API 36, cached in `out/cache/`) ships the same Mesa 24.0.8 prebuilts, gbm_gralloc via allocator 2.0 / mapper 2.1, the same fake composer, and an rc that forces `debug.renderengine.backend gles`. So moving Route M to redroid 16 changes only the Android base. Rebuild with `-Dplatform-sdk-version=36`; the rc could then switch RenderEngine to `skiavk`.

Results are saved in `out/mesa-shim-results/` (`vulkaninfo-*.txt`, `glver-*.txt`, `gles31-extensions-*.txt`).

### 16.15 A third Mesa variant: BayLibre's low-risk performance commits, and a smoke test (2026-10-29)

BayLibre's `android-17-pvr-perf` branch (`f0cabdd9b56`, 2026-10-10) adds about 60 commits on top of their Android support series, mostly in the pco compiler (co-issue scheduling, a preamble pass, preloads, register allocation). Rebasing all of them onto 26.3 stops at real conflicts:
- `f06b124f32b` (barrier wakeups): 26.3 already has its own fix, `8834fe3b869`.
- `3309d19e2e5`: already fixed in 26.3.
- `93a96eb1aa6`: needs moving into 26.3's restructured query code.
- `420692eda74`: conflicts with 26.3's rewritten NIR options.

A hand-merged compiler cannot be tested without a GPU, so I stopped there.

**`VARIANT=perf`** is base plus the 9 commits that apply cleanly and mostly touch the driver rather than the compiler:
- `46289980731` don't wait for the previous submit on the CPU (CPU/GPU pipelining);
- `6a1840a4f8e` and `aaf1e9240a0` reuse spill, scratch and SPM buffers across draws and renders;
- `0fd143219a7` merge DMAs of adjacent vertex attributes;
- `3da4a58fbff` and `3b86bb3287d` buffer-copy alignment fixes;
- `45c083bc13e` 8/16-bit scaled vertex formats;
- `3bfbc068020` egl/android: hide `EGL_KHR_no_config_context` below ES 3;
- `afff9ee1d1d` a pco source-modifier fix.

`9f4d4939b86` ("skip fragment shaders with no effect") conflicts, so it is left out. Build: `VARIANT=perf ./scripts/23-build-mesa-android.sh` (worktree `src/mesa-perf`, own host tools). It also passes the redroid 13 link check with 0 problems and reaches GLES 3.1 on the shim.

**Smoke test.** `ASSERTS=1 ./scripts/24-mesa-shim-probe.sh` (with `VARIANT=` as needed) builds a separate shim copy with Mesa's asserts on and runs `scripts/mesa_glsmoke.c`. That is GLES 3.1 work typical of apps, 120 frames into a 720×1280 two-target framebuffer:
- texturing with mipmaps, a UBO, discard, blending, `dFdx`, instanced draws;
- a compute shader with shared memory and `barrier()`;
- periodic `glReadPixels`.

It can't check pixels, but it runs the real Zink → SPIR-V → pco compile, pipeline creation, command recording and submission. **base: OK. perf: OK** (no assert, no GL error). The apercel variant fails at Vulkan start with the timeline assertion (section 16.14).

**Variant order for BOARD-DAY step 8:** base first (closest to upstream), then perf (expected faster, same feature level), apercel only to compare.

### 16.16 Upstream prep: what a mainline A733 GPU node would look like (draft, 2026-10-29)

Mainline already has two of the needed pieces, and a third is in review:
- The A733 power-domain driver marks **GPU_CORE always-on** (`b462a227d854`), so a GPU node needs only `PD_GPU_TOP` (= 5 in `include/dt-bindings/power/allwinner,sun60i-a733-pck-600.h`).
- The PowerVR binding has a "single unified power domain" group (K1, K3, TH1520).
- The A733 CCU series v6 (Junhui Liu, 2026-10-09, in review) defines `CLK_GPU0` (133), `CLK_BUS_GPU0` (134), `CLK_MBUS_GPU0` (78), `CLK_AHB_GPU0` (67), `CLK_PLL_GPU0` (23) and `RST_BUS_GPU0` (31). Mainline numbering differs from the vendor's `RST_BUS_GPU0` = 32.

**Clock mapping.** The binding's names are `core`, `mem`, `sys`, which map naturally to `CLK_GPU0`, `CLK_MBUS_GPU0` and `CLK_BUS_GPU0`. That is three clocks, like the TH1520. The vendor driver never touches the MBUS gate. A mainline node must reference it anyway, or `clk_disable_unused` may turn the GPU's memory port off at boot.

**Binding change** (`Documentation/devicetree/bindings/gpu/img,powervr-rogue.yaml`): add `allwinner,sun60i-a733-gpu` in three places:
1. the `img,img-bxm-4-64` compatible enum, with `spacemit,k3-gpu` and `thead,th1520-gpu`;
2. the `if` block that requires three clocks (`img,img-ge7800`, `img,img-gx6250`, `thead,th1520-gpu`);
3. the `if` block for one unified power domain (`spacemit,k1-gpu`, `spacemit,k3-gpu`, `thead,th1520-gpu`).

**SoC dtsi node** (once `sun60i-a733.dtsi` and the CCU land). Untested. Check `reg` against the A733 memory map; the vendor DT says `0x1800000`, size `0x8ffff`:
```dts
gpu: gpu@1800000 {
	compatible = "allwinner,sun60i-a733-gpu", "img,img-bxm-4-64", "img,img-rogue";
	reg = <0x01800000 0x90000>;
	interrupts = <GIC_SPI 63 IRQ_TYPE_LEVEL_HIGH>;	/* vendor: IRQGPU 63, IRQGPUDVFS 64 */
	clocks = <&ccu CLK_GPU0>, <&ccu CLK_MBUS_GPU0>, <&ccu CLK_BUS_GPU0>;
	clock-names = "core", "mem", "sys";
	resets = <&ccu RST_BUS_GPU0>;
	power-domains = <&pck600 PD_GPU_TOP>;
	status = "disabled";
};
```
Board DTS: `&gpu { status = "okay"; };`. The GPU rail is AXP318W `dcdc4` (vendor `reg_dcdc4`, always-on), so the node can stay without a supply until the driver does DVFS.

**Driver line** (`drivers/gpu/drm/imagination/pvr_device.c`, `pvr_gpu_support_level()`): mainline lists only SUPPORTED cores today. A first step would be `case PVR_PACKED_BVNC(36, 56, 104, 183): return PVR_GPU_EXPERIMENTAL;`, so the driver still needs `exp_hw_support=1` but no longer calls the GPU unknown. Imagination promotes cores to SUPPORTED after Mesa conformance (as `e55fead22ff9` did for 36.52.104.182), and the K3 work will likely send this line first.

**Before sending anything:** board evidence from the Zero 3W (apercel and the shim already show the GPU and firmware work with this register layout), and `make dtbs_check`. The kernel and Mesa both require AI-assisted patches to be disclosed (kernel `Documentation/process/` guidance on coding assistants; Mesa's `AGENTS.md`). Write the patches and their descriptions yourself, and use these notes as a checklist.

### 16.17 What Imagination documents, what is under NDA, and why nobody has to reverse-engineer this GPU (checked 2026-10-29)

**Public documentation:**

| What | Scope |
|---|---|
| *Rogue Registers Referenced in the KM Driver* (126 pages) and *Rogue Registers Referenced in the Firmware Interface* (129 pages), marked "Public", redistribution permitted | Only the registers the open kernel driver and the firmware interface touch. Released April 2022 with the open-source announcement; zip at `developer.imaginationtech.com/wp-content/uploads/2023/12/rogue-registers-description-docs.zip`. |
| *PowerVR Instruction Set Reference* (docs.imgtec.com, first published 2014) | Series 6XT USC instructions at assembly level, for shader developers. It says itself: "Refer to the main PowerVR ISR document (**NDA required**) for precise information regarding feature availability." |
| Architecture and performance guides, PowerVR SDK, tools | App-developer level |
| **The open driver code itself** | The real hardware documentation. Mesa `src/imagination`: 1,422 of about 1,780 commits on our branch are from `imgtec.com`. It holds machine-readable hardware descriptions: 16 `csbgen` XML files (PDS, VDM, CDM, PPP, texture and PBE state, plus the next-generation "volcanic" architecture), the shader ISA and encodings in `pco/pco_isa.py`/`pco_ops.py`, and per-core feature/quirk tables (`common/device_info/bxm-4-64.h` …). The kernel side has `pvr_rogue_cr_defs.h` and `pvr_rogue_fwif*.h` (about 11,800 lines in the Orange Pi copy). All MIT/GPL. |

**Not public:**
- The full ISA reference ("ISR", NDA).
- The GPU TRM/integration manuals and the closed DDK, which SoC licensees such as Allwinner get under licence. Our Route A blobs are that DDK.
- **The firmware source.** The firmware ships as binaries in `linux-firmware` under `LICENSE.powervr`: redistributable unmodified, "**No reverse engineering, decompilation, or disassembly of this software is permitted**", and only for use with Imagination-licensed products.
- **The A733 user manual (1,938 pages) documents only the SoC glue:**
  - the GPU PLL;
  - `GPU0_CLK_REG` at `0x0B20`, a cycle-masking divider: `GPU0_CLK = source × (16 − M) / 16`;
  - the gating/reset register and the AHB and MBUS gate switches;
  - the PCK-600 power domains.
  The GPU itself appears only as "IMG BXM-4-64 MC1" in the block diagram.

**Why this works without reverse engineering:** since 2022 Imagination writes the open stack itself, in public:
- the Mesa Vulkan driver (from Frank Binns' first commit, 2022-02-25);
- the kernel `drm/imagination` driver (mainline since v6.8);
- firmware binaries in linux-firmware;
- Mesa CI on its own hardware, conformance submissions, Zink for GL/GLES.

Their stated reasons are long-term support for industrial/IoT products and letting "developers, silicon vendors, and OEMs" control their own graphics stack. Outside contributors (Collabora, Igalia, ISCAS, Icenowy, BayLibre, CheezeCS) add SoC glue, fixes and Android integration on top. They do not decode the GPU. For the A733, the only "unknown" parts are SoC-specific (clocks, resets, power domains), and those are in Allwinner's GPL BSP and user manual.

**What this means for our work:**
- Read the open drivers and the two public register PDFs. Don't disassemble the firmware: its licence forbids it, unlike the ARC DDR-PMU work.
- The DDK blobs in Route A come with Allwinner/Radxa's terms, so they stay out of git (`out/` is ignored).
