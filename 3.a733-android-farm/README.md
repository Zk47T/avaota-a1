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

## 1. Is there a working PowerVR stack for A733 to build on? Yes, four

| Stack | What it is | Where | Role here |
|---|---|---|---|
| **Vendor Android 13** | Allwinner's Android userspace: EGL, GLES 3.2, Vulkan, gralloc 4, OpenCL, **DDK 24.2@6643903**. Also the **kernel driver source of the same build** (MIT/GPL). | `gitlab.com/aw_android13/gpu/gpu` and `.../lichee/bsp` → `modules/gpu/img-bxm/android/rogue_km`, branch `a733-radxa-v1.0` (Radxa's public A733 Android 13 SDK) | **Plan A.** Both halves come from one build. |
| Vendor Linux (Orange Pi 6.6 BSP) | Upstream-style PowerVR driver in `bsp/drivers/gpu/imagination` (`CONFIG_AW_DRM_POWERVR`, binds `img,gpu`, manual clock-and-reset power sequence). Firmware `powervr/rogue_36.56.104.183_v1.fw` from Allwinner's libgpu. Userspace is Mesa with apercel's BVNC patch; libgpu's DDK 24.2@6603887 libraries expect the DDK kernel UAPI (section 16.7). | Orange Pi kernel `bsp/` (`2ac08e8c`) and `gitlab.com/tina5.0_aiot/product/linux/external/libgpu` (`144487e8`) | **Route L** (section 16.6): the first GPU test. The option is off in every Orange Pi config we checked, so nobody has shipped this driver here. The module builds on the build PC (2026-10-28) but has not run. |
| AIoT rogue_km (tina5 BSP) | DDK-style Linux driver for BVNC 36.56.104.183 (`RGX_BVNC := 36.56.104.183`), DDK 24.2@6603887, with `sunxi_secure_config()` | `gitlab.com/tina5.0_aiot/lichee/bsp` → `modules/gpu/img-bxm/linux/rogue_km` (`a5fe1970`) | Origin of the secure-reset step (section 4). Not what the Orange Pi 6.6 tree builds. |
| Radxa A733 Bullseye image (reference) | Radxa's prebuilt Linux GPU stack for A733: DKMS `img-bxm-dkms` 0.1.0-2, `pvrsrvkm.ko` for kernel 5.15.147-14-a733 (DDK 24.2@6603887, Linux WS build), IMG user-space 24.2.6603887, firmware `rgx.fw` / `rgx.sh` 36.56.104.183 | Public apt repo `radxa-repo.github.io/a733-bullseye`; image `radxa-a733_bullseye_kde_r2.output_512.img.xz` (sha256 `1b5604fe…`) | Reference only. Compare the Linux driver and its start sequence. Not a base: 5.15 kernel. Mirror the repo before it disappears. |
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
- Orange Pi 6.6 kernel tree (PowerVR driver, PCK-600, CCU, board DTS): https://github.com/orangepi-xunlong/linux-orangepi
- Orange Pi build (kernel configs): https://github.com/orangepi-xunlong/orangepi-build
- Mainline DRM driver: https://github.com/torvalds/linux/tree/master/drivers/gpu/drm/imagination
- Mesa PowerVR source (freedesktop, main): https://gitlab.freedesktop.org/mesa/mesa/-/tree/main/src/imagination
- linux-riscv mailing-list archive (lists.infradead.org; the A733 CCU v5 thread in section 16.3) and linux-firmware (GitLab, `powervr/`), both checked 2026-10-28

## 16. Mainline status and upstream commits (checked 2026-10-28)

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
| BVNC 36.56.104.183 (our GPU) | `pvr_gpu_support_level()` in `pvr_device.c` marks 33.15.11.3 (the AXE-1-16M the docs list), 36.52.104.182 (BXM-4-64, TH1520) and 36.53.104.796 (the BXS-4-64 MC1 the docs list) as supported. 36.56.104.183 is absent. | Missing. Mainline refuses unknown BVNCs unless `exp_hw_support` is set. The Orange Pi 6.6 driver has no BVNC table. Mesa's canonical tree (freedesktop GitLab, main) lists 36.52.104.182 and 36.53.104.796 only. |
| GPU binding for A733 | `img,powervr-rogue.yaml`: no Allwinner entry | Missing. The mainline BXM-4-64 pattern is `"thead,th1520-gpu", "img,img-bxm-4-64", "img,img-rogue"`. The vendor tree and the kit's driver use `img,gpu`. |
| GPU firmware `rogue_36.56.104.183_v1.fw` | linux-firmware `powervr/`: the TH1520's `rogue_36.52.104.182_v1.fw` returns 200, ours returns 404 | Missing upstream. Allwinner's libgpu has the file (section 16.7). |
| A733 sunxi MMC driver | `drivers/mmc/host/sunxi-mmc.c`: no A733 match | Binding only (`8dc697aa…`) |
| AXP318W regulators | `drivers/regulator/axp20x-regulator.c` and `drivers/mfd/axp20x.c`: no axp318w | "[PATCH v3 4/4] regulator: axp20x: add support for the AXP318W", July 2026 (lkml.iu.edu/2607.2/02884.html). The message gives no DT compatible and no test board. |

### 16.4 Out of tree

- **apercel** (https://github.com/TumRedSun/apercel): a kernel driver built from upstream drm/imagination for the 6.6.98-sun60iw2 BSP (module `apercel`), plus a Mesa 26.1.8 patch for BVNC 36.56.104.183. Self-reported on one board, an Orange Pi 4 Pro (A733), with the GPU at 1.008 GHz. Its power-on is `clk_parent`, `clk`, `clk_bus`, a 1 µs delay, then one `reset_control_deassert`. A grep of its driver source finds no `0x0a0000b0`, no `0x01880014` (DRM_CTRL), no `0x07066000` (PPU) and no `0x02002b20` (GPU clock register). Its README says it binds by `img,gpu`.
- **Radxa A733 Bullseye image** (`prebuilt-image/radxa-a733_bullseye_kde_r2.output_512.img.xz`, sha256 `1b5604fe…`): ships a vendor Linux driver as DKMS package `img-bxm-dkms` 0.1.0-2 (DDK 24.2@6603887, Linux WS build), a built `pvrsrvkm.ko.xz` for kernel 5.15.147-14-a733, IMG user-space 24.2.6603887, and firmware 36.56.104.183. Its `rgx.sh` is byte-identical to the kit's. Its `rgx.fw` is not.

### 16.5 What this means for us

1. **The power domains are mainline-shaped.** The A733 PCK-600 driver puts each domain's PPU block at `base + 0x1000 × index`. Domain 5 (GPU_TOP) is at `0x07065000`, and domain 6 (GPU_CORE) is at `0x07066000`, the address the kit writes `0x8` to (`PPU_PWPR`, `POWER_MODE_ON`). The Zero 3W tree requests domain 5 only. The Orange Pi 6.6 SoC DT keeps its GPU_CORE node commented out, and Route L doesn't need GPU_CORE. The Android path does the manual write, as the vendor Android does. Board check: read `PPU_PWSR` (+0x8, bits 3:0) at `0x07065008` and `0x07066008`; `0x8` means on. Read both before loading the driver and after the write.
2. **The minimal sequence is the vendor's Linux one.** The Orange Pi 6.6 driver powers the GPU with `clk_parent`, `clk` and `clk_bus`, a 1 µs delay, then one reset deassert: the same code apercel uses. No PPU, secure or bit-27 write. Route L tests that path on our board. The Android path keeps the writes the vendor Android and AIoT code make.
3. **Secure-by-default clocks.** The CCU review says the A733's PLLs and bus dividers are secure by default, and asks whether things work only because secure boot is not enforced. One tester reports the registers work on a Radxa Cubie A7S without secure boot. Those measurements are AI-assisted, and the author asks that they not count as Tested-by.
4. **PMIC naming is unresolved.** Every vendor device tree we checked defines `x-powers,axp8191`: both Orange Pi trees, and Radxa's Cubie A7A, A7S and A7Z. The schematic and the July 2026 patch say AXP318W. Nothing we found proves they are the same die.
5. **Names differ from mainline.** The PCK-600 compatible is `allwinner,sun60i-a733-pck-600` upstream and `allwinner,sun60iw2-pck-600` in the Zero 3W tree. Firmware is named `rogue_<BVNC>_v1.fw` upstream and `rgx.fw.<BVNC>` in the vendor tree.

Upstream does not run the Zero 3W. Its mainline gaps are the CCU, the device tree, the BVNC and the firmware. Those are the commits to watch, or to write, if we want a mainline path.

### 16.6 GPU routes and test order

Four ways to drive this GPU on our board, ordered by evidence and by how much each test tells us.

| Route | Driver | Firmware | Userspace | Status |
|---|---|---|---|---|
| **L** Linux host | Orange Pi 6.6 BSP `bsp/drivers/gpu/imagination` (`CONFIG_AW_DRM_POWERVR=m`), binds `img,gpu` | `/lib/firmware/powervr/rogue_36.56.104.183_v1.fw` (libgpu, v3, open-source) | Mesa with apercel's BVNC patch. Not libgpu's DDK libraries (section 16.7). | First test. Module builds (2026-10-28, `out/route-l/` on the build PC); not run. |
| **A** redroid | kit's `pvrsrvkm-android.ko` (Android DDK 6643903) | `/lib/firmware/rgx.fw.36.56.104.183` (Android copy) | Android blobs in the container | Built, never run. Keeps the PPU, secure and bit-27 writes. |
| apercel (fallback) | out-of-tree kbuild module `apercel` (`driver/`, upstream drm/imagination files kept) | `/lib/firmware/apercel/rogue_36.56.104.183_v1.fw` (the Allwinner file, copied by hand; apercel does not ship it) | Mesa with `mesa/apercel-mesa.patch` | Tested by its author on an Orange Pi 4 Pro only. Not proven on the Zero 3W. Use it if Route L fails at the driver level. |
| Radxa DKMS (reference) | DDK 6603887, Rogue style, for 5.15 | Radxa `rgx.fw` (v2, not open-source) | Radxa libraries | Not for our 6.6 kernel. |

**Route L, step by step.** Step 1 runs on the build PC.
1. Build PC, done 2026-10-28 in a copy of the kit tree (`/mnt/project/route-l-build/linux-orangepi-6.6`; the kit tree itself was not changed). `CONFIG_AW_DRM_POWERVR=m` and `make olddefconfig` add three helper modules that the kit's `.config` did not have: `CONFIG_DRM_EXEC=m`, `CONFIG_DRM_GEM_SHMEM_HELPER=m` and `CONFIG_DRM_SCHED=m`. Five config lines change in all (`out/route-l/config-delta.txt`). Then `make modules_prepare`, `make modules` and `make M=bsp/drivers/gpu/imagination modules` all exit 0. The one warning is an unused variable in the BSP's `drm_gpuvm.c`. `powervr.ko` has vermagic `6.6.98-sun60iw2-redroid SMP preempt mod_unload aarch64`, needs `gpu-sched`, `drm_shmem_helper` and `drm_exec`, and matches `img,gpu` (`of:N*T*Cimg,gpuC*`). MODVERSIONS is off in the kit config, so a load checks vermagic only. The four modules and their hashes are in `out/route-l/` on the build PC (`SHA256SUMS`). Not run on hardware yet.
2. Board: install the modules and the firmware. Copy the four modules from `out/route-l/` (`powervr.ko`, `gpu-sched.ko`, `drm_shmem_helper.ko`, `drm_exec.ko`) to `/lib/modules/6.6.98-sun60iw2-redroid/extra/`, then run `sudo depmod -a`. The kit's kernel package does not carry them, and the running kernel needs no rebuild. Then install the firmware with `sudo install -D -m 0644 rogue_36.56.104.183_v1.fw /lib/firmware/powervr/rogue_36.56.104.183_v1.fw` (sha256 `3974e79f…`).
3. Board: unload `pvrsrvkm` if it is loaded, then `sudo modprobe powervr`. `modprobe` loads `gpu-sched`, `drm_shmem_helper` and `drm_exec` first, from the `depmod` index.
4. Check `dmesg` for `loaded firmware powervr/rogue_36.56.104.183_v1.fw` and `FW version v1.0 (build 6852738 OS)`. Then `ls /dev/dri` (card0 and renderD128) and `cat /sys/kernel/debug/dri/*/name` (expect `powervr`).
5. Userspace comes after the module works, and it is not libgpu's. libgpu's libraries are DDK 24.2 builds, and `libsrv_um` calls `DRM_IOCTL_PVR_SRVKM_INIT`, which the upstream UAPI (`pvr_drm.h`) does not define. Use Mesa built with `mesa/apercel-mesa.patch`, then check with `vulkaninfo --summary`. Not tried.
6. PD readbacks before and after step 3: `devmem 0x07065008` and `devmem 0x07066008`. `0x8` means on.

Firmware errors look different from hardware errors. `firmware not available yet, deferring` means the file is missing or in the wrong path. `Unsupported fw info version 2` means the older info format; the Radxa and Android `rgx.fw` copies are info v2. `FW info format mismatch` means a header layout the driver does not parse. `Unsupported FW version` means the file lacks the open-source flag or has a major version the driver does not know. `FW built for incorrect GPU ID` means another BVNC.

Order: Route L first. It uses the vendor's own minimal sequence, so a Route L failure at power, clock or probe points at the board, the DT or the firmware, not at the Android port. If Route L boots and Route A doesn't, the difference is in the Android-only writes.

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
| Mesa (upstream) | `gitlab.freedesktop.org/mesa/mesa` main, `src/imagination/vulkan/pvr_physical_device.c` | The BVNC switch lists 36.52.104.182 and 36.53.104.796 only. |
| apercel | `TumRedSun/apercel`, `mesa/apercel-mesa.patch` | Adds `case PVR_BVNC_PACK(36, 56, 104, 183): return true;` to the device check in `src/imagination/vulkan/pvr_physical_device.c`. |

**Potential upstream commits, from this evidence**
- Kernel: one line in `pvr_gpu_support_level()` for 36.56.104.183, as SUPPORTED or EXPERIMENTAL. The firmware carries the device info, so the driver should need no feature table for it. Validate on hardware first.
- Mesa: `PVR_BVNC_PACK(36, 56, 104, 183)` in `src/imagination/vulkan/pvr_physical_device.c`. apercel adds it along with limit changes.
- Device tree: an Allwinner SoC compatible, then `img,img-bxm-4-64` and `img,img-rogue`, as the TH1520 entry does in the binding (section 16.3). Upstream has neither an Allwinner GPU compatible nor an A733 SoC DTS.
- Clocks: the A733 CCU series in review (section 16.3).
- Firmware: the libgpu file is marked open-source. Check its licence before any redistribution.

