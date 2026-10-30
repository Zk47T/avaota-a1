# A733 mainline: status checklist and own-commit plan

Status of the Allwinner A733 (sun60i) and the Orange Pi Zero 3W in mainline Linux, U-Boot, TF-A and the distributions. **Checked 2026-10-30** against:

- **Kernel trees** (`3.a733-android-farm/src/upstream/`, git-ignored), each searched for every `sun60i`, `a733` and `axp318` hit:
  - torvalds master `d89e1d186` (2026-10-29, the 7.4 merge window);
  - linux-next `next-20261029`;
  - sunxi `for-next`.
- **Patch queues:** kernel.org patchwork (every patch naming the A733 since April), the U-Boot list (ozlabs patchwork) and TF-A Gerrit.
- **On GitHub:** meta-sunxi, Armbian, SyterKit, sunxi-tools and xfel.
- **Board and vendor sources:** the Zero 3W schematic V1.2 and the Orange Pi 6.6 BSP.

Details and sources: main README 3.14. To re-check: `python3 -I 3.a733-android-farm/scripts/60-mainline-watch.py`.

**Legend**

| Mark | Meaning |
|---|---|
| ✅ | in mainline (master on 2026-10-29, so v7.4) |
| 🔄 | someone else's series is in review: theirs, not ours |
| ⬜ | **nobody is working on it** (no series found on 2026-10-30) |
| 🎯 | ⬜ and a good **own commit** for us: independent, testable on the Zero 3W, sized for one person |

"A523 ✅" means the closely related A523/T527 already has mainline support for that block. The A733 commit is then mostly a compatible string, plus whatever the manuals show is different.

## 1. Linux kernel

### 1.1 SoC base and boot-critical

| | Block | Who / state | Zero 3W | Notes |
|---|---|---|---|---|
| ✅ | CPUs, GICv3, arch timer, PSCI | generic | ✓ | runs today from the vendor boot chain |
| 🔄 | SoC `sun60i-a733.dtsi` | Enzo Adriano v1 (2026-06-13), no v2 | ✓ | waits for the CCU; uses a 24 MHz crystal, but the Zero 3W has **26 MHz** |
| ⬜ 🎯 | **Board DTS `sun60i-a733-orangepi-zero3w.dts`** | nobody | ✓ | as soon as the `.dtsi` lands |
| ⬜ 🎯 | Board DTS `sun60i-a733-orangepi-zero4.dts` | nobody | – | the same SoC; GbE needs GMAC210 |
| ⬜ | Board DTS for the Orange Pi 4 Pro | nobody in Linux (Inferno has a U-Boot DT) | – | |
| 🔄 | Main CCU + PRCM (R-CCU) | Junhui Liu v6 (2026-10-09) | ✓ | |
| ⬜ 🎯 | **CPU PLL CCU** (`0x08870000`: `PLL_CPU_L`, `PLL_CPU_B`, `PLL_CPU_DSU`) | nobody; **not part of CCU v6** | ✓ | vendor `bsp/drivers/clk/sunxi-ng/ccu-sun60iw2-cpupll.c`, 351 lines; prerequisite for CPU DVFS |
| ✅ | RTC + RTC CCU (19.2/24/26 MHz) | merged | ✓ | |
| ✅ | Pinctrl, main + R | merged (7.4) | ✓ | |
| 🔄 | Pinctrl I/O-voltage and withstand fixes | Vinicius Pedrosa, Andre Przywara (2026-10-12/13) | ✓ | |
| ✅ | PCK-600 power domains | merged | ✓ | |
| ✅ | DMA | merged | ✓ | |
| ✅ | NMI (PMIC interrupt) | merged (binding) | ✓ | |
| 🔄 | UART | Vinicius Pedrosa v2 (2026-10-19) | ✓ | |
| ⬜ 🎯 | **Watchdog** | nobody; A523 ✅ | ✓ | **register map identical to the A523's** (A733 UM vs A527 UM, offsets 0x00–0x18): binding + DT node only |
| ⬜ 🎯 | **SID / eFuse (nvmem)** | nobody; A523 ✅ | ✓ | feeds thermal calibration, the CPU speed bin, and the UFS calibration words (SID 0x60/0x64) |
| ⬜ 🎯 | **Hardware spinlock** | nobody | ✓ | you already did the D1 one |
| ⬜ 🎯 | System control / SRAM controller | nobody; A523 ✅ | – | needed later by VE/DE |
| 🔄 | Message box (to the RISC-V E902) | Tim Michals v2 (2026-09-27) | – | |
| ⬜ | E902 remoteproc | nobody | – | after the message box |

### 1.2 Power, clocks, thermal

| | Block | Who / state | Zero 3W | Notes |
|---|---|---|---|---|
| 🔄 | PMIC AXP318W (vendor "AXP8191") | Andre Przywara + Jerome Brunet v8 (2026-09-10), reviewed, not applied | ✓ | the Zero 3W has no AXP515 |
| ⬜ 🎯 | **CPU DVFS**: speed bins in `sun50i-cpufreq-nvmem` + OPP tables | nobody | ✓ | after the CPU PLL CCU and SID; vendor OPPs are in the BSP DT |
| ⬜ | DSU frequency | nobody | ✓ | vendor `dsufreq`; no mainline equivalent yet (research) |
| ⬜ 🎯 | **Thermal sensors** in `sun8i_thermal` | nobody for the A733. A523 THS is 🔄 (Mikhail Kalashnikov v6, changes requested). | ✓ | the THS register layout matches the A523's (UM): build on that driver, and cc Mikhail |
| ⬜ | DRAM devfreq (DMC) | nobody | ✓ | research; ties to 4.a733-ddr |
| ⬜ 🎯 | GPADC | nobody; A523 ✅ | – | compatible |

### 1.3 Storage

| | Block | Who / state | Zero 3W | Notes |
|---|---|---|---|---|
| ✅ | SD (SMHC0), SDIO (SMHC1) | merged (`sun60i-a733-mmc`, falls back to D1) | ✓ | |
| ⬜ 🎯 | **eMMC (SMHC2) compatible** | nobody | ✓ (footprint) | the A523 has `-emmc` |
| ⬜ 🎯 | **HS200/HS400 in `sunxi-mmc`** | nobody ("TODO: HS400" in the driver) | ✓ | a feature, not just a compatible; the BSP has the data-strobe calibration |
| ⬜ 🎯 | **UFS host glue + M-PHY** | nobody | ✓ (footprint) | large: BSP `bsp/drivers/ufs`, 2,089 lines; UM gives one page (main README 3.13) |
| ✅ | SPI | merged (binding) | – | |
| ⬜ | Raw NAND | nobody | – | not on the Zero 3W |

### 1.4 USB, PCIe, network

| | Block | Who / state | Zero 3W | Notes |
|---|---|---|---|---|
| 🔄 | USB 2.0 PHY | Vinicius Pedrosa (2026-10-29) | ✓ | |
| ⬜ 🎯 | **MUSB (OTG), EHCI/OHCI** | nobody; A523 ✅ | ✓ | compatibles; you already did MUSB work |
| ⬜ 🎯 | **USB 3.1 DWC3 glue** | nobody | ✓ | large |
| ⬜ 🎯 | **Cadence combo PHY** (USB3 / PCIe / DP) | nobody | ✓ | large: BSP `sunxi-cadence-combophy.c`, 4,587 lines |
| ✅ | Type-C FUSB302 | driver merged | ✓ | board DT only |
| ⬜ | DP alt mode on USB-C | nobody | ✓ | after USB3 + PHY + display |
| ⬜ 🎯 | **PCIe root complex** (DesignWare glue) | nobody | ✓ (FPC) | large: BSP `pcie-sunxi-plat.c`, 1,275 lines; Gen3 training notes from edk2-a733 and Inferno's U-Boot |
| 🔄 | Ethernet GMAC210 | Jerome Brunet net-next v3, changes requested | – | Zero 4 / 4 Pro |
| ⬜ | Wi-Fi/BT AIC8800 (module 20800D8) | no mainline driver | ✓ | outside the SoC; vendor driver, large |

### 1.5 Display, GPU, multimedia, NPU

| | Block | Who / state | Zero 3W | Notes |
|---|---|---|---|---|
| ⬜ 🎯 | **IOMMU** | nobody; A523 ✅ (binding) | ✓ | needed by display, VE and CSI |
| ⬜ | Display engine 3.5x, TCON top/LCD/TV | nobody | ✓ | large |
| ⬜ | HDMI 2.0 TX + PHY | nobody | ✓ (mini-HDMI) | large |
| ⬜ | MIPI DSI ×2 + combo D-PHY | nobody | ✓ (DSI FPC) | large; you already fixed `drm/sun4i` DSI on the A100 |
| ⬜ | eDP, LVDS, RGB, G2D | nobody | – | |
| ⬜ 🎯 | **GPU binding + DT node** (`allwinner,sun60i-a733-gpu`) | nobody | ✓ | small, like `spacemit,k3-gpu`. Adding the BVNC to `drm/imagination` and the firmware to linux-firmware is Imagination's part. Farm README 16.16. |
| ⬜ | Video engine (new Cedar generation, decode + encode) | nobody | ✓ | large; Cedrus doesn't cover it |
| ⬜ | Deinterlace | nobody | – | |
| ⬜ 🎯 | **Camera: CSI/CSIC + MIPI CSI** | nobody | ✓ (2× CSI FPC) | follows your D1 CSIC and OV3660 work. The ISP is undocumented: start with raw capture. |
| ⬜ | NPU (VeriSilicon VIP) | nobody | – | the A523 uses `vivante,gc` with etnaviv |

### 1.6 Audio and small I/O

| | Block | Who / state | Notes |
|---|---|---|---|
| ⬜ 🎯 | I2S/TDM, SPDIF (OWA) | nobody; A523 ✅ | compatibles |
| ⬜ | HDMI audio, DMIC | nobody | |
| ⬜ 🎯 | IR receiver, LEDC | nobody; A523 ✅ | compatibles |
| ⬜ 🎯 | LRADC keys | nobody (A100/A133 merged 2026) | compatible |
| ⬜ | PWM (30 channels, new PWM IP) | nobody, and no mainline driver for this PWM generation | medium |
| ⬜ | Crypto engine (and its TRNG) | nobody | medium; Inferno U-Boot has the TRNG |

## 2. Bootloaders, firmware, tools

| | Item | Who / state | Notes |
|---|---|---|---|
| ✅ | xfel A733 FEL | merged (`chips/a733.c`) | |
| ⬜ 🎯 | **sunxi-tools FEL support** (SoC ID 0x1903) | nobody (A523 0x1890 is there) | small: SRAM layout, swap buffers, watchdog |
| ⬜ 🎯 | **OpenOCD A733 target config** | nobody | small: JTAG on PB0–PB3 function 7 |
| ⬜ 🎯 | **SyterKit `boards/orangepi-zero3w`** | nobody (A7A, A7Z exist) | LPDDR5 `dram_para` from 4.a733-ddr |
| 🔄 | U-Boot A733 base (SPL, clocks, pinctrl, MMC, UART) | Yixun Lan v3 (2026-01, stale). Inferno Embedded has branches on GitHub, not posted. | |
| ⬜ | U-Boot A733 LPDDR5 DRAM init (on the list) | not posted. Inferno has code with "open-source PMU firmware". | **contested**: talk to Alastair D'Silva before starting your own |
| 🔄 | U-Boot AXP318W | Andre Przywara series | |
| ⬜ 🎯 | U-Boot Orange Pi Zero 3W board + defconfig | nobody | after the A733 base lands |
| 🔄 | TF-A A733 | Gerrit topic `allwinner_a733_support` (Jernej Škrabec, Alastair D'Silva) | |
| ⬜ | linux-firmware PowerVR 36.56.104.183, Mesa enablement | Imagination / BayLibre | not ours |

## 3. Distributions and documentation

| | Item | State | Notes |
|---|---|---|---|
| ⬜ 🎯 | **meta-sunxi `sun60i.inc` + `orange-pi-zero3w.conf`** | nobody | `DEFAULTTUNE = "cortexa76-cortexa55"`. Submit once Linux has the DTS and U-Boot boots the board; draft now. You already have PR #467 merged there. |
| ✅ | Armbian Zero 3W | vendor kernel only | a mainline-kernel variant later |
| ⬜ | Buildroot defconfig | nobody | after mainline |
| ⬜ 🎯 | linux-sunxi wiki: A733 and Orange Pi Zero 3W pages | check first: the wiki blocks this PC | facts from main README 3.11–3.14 |

## 4. Own-commit plan

These are only items where nobody else has a series, so every commit is ours from scratch.
- **Not ours:** the CCU, UART, AXP318W, USB2 PHY, GMAC210, message box, pinctrl fixes, `.dtsi`, TF-A and the U-Boot base. Leave them to their authors.
- **How independent the patches are:** a binding or driver patch can be posted now; it doesn't depend on unmerged code.
- **How to test them:** use a local tree of master plus the CCU v6, AXP318W v8, UART v2 and Enzo's `.dtsi`, booted from the vendor U-Boot. DT nodes for the SoC wait for the `.dtsi` to land, then go on top of it.

**Tier 1: small, post first**

| # | Commit(s) | Size | What it needs |
|---|---|---|---|
| 1 | sunxi-tools: A733 FEL | ~100 lines | board over USB (FEL button) |
| 2 | watchdog: `allwinner,sun60i-a733-wdt` binding (register map verified identical) | binding + DT node | test with `wdctl`, a reboot |
| 3 | nvmem: A733 SID | small | dump and compare with the vendor kernel's `/sys/bus/nvmem` |
| 4 | hwspinlock: A733 compatible | tiny | |
| 5 | MUSB, EHCI/OHCI, IOMMU, GPADC, IR, LEDC, LRADC, I2S/SPDIF compatibles | one small series each | compare each block in the A733 UM with the A527 UM first |
| 6 | OpenOCD A733 config | small | JTAG adapter |
| 7 | SyterKit Zero 3W board | small–medium | |

**Tier 2: new drivers or features, medium**

| # | Commit(s) | Size | Notes |
|---|---|---|---|
| 8 | **CPU PLL CCU** (`allwinner,sun60i-a733-cpupll` + `ccu-sun60i-a733-cpupll.c`) | medium | a separate block from the main CCU; cc Junhui Liu |
| 9 | **CPU DVFS** (speed bin + OPPs) | medium | after 3 and 8 |
| 10 | **Thermal** in `sun8i_thermal` | medium | coordinate with the A523 THS v6 |
| 11 | **eMMC compatible + HS200/HS400 in `sunxi-mmc`** | medium | also helps other sunxi SoCs |
| 12 | **GPU binding + DT node** | small–medium | the farm uses the result |
| 13 | **Camera CSI/CSIC raw capture** | medium–large | builds on your D1 CSIC driver |

**Tier 3: large, each a project**

| # | Commit(s) | Notes |
|---|---|---|
| 14 | PCIe root complex + Cadence combo PHY | Zero 3W FPC; a strong portfolio piece |
| 15 | USB 3.1 DWC3 + combo PHY (+ DP alt mode) | shares the PHY with 14 |
| 16 | UFS host glue | main README 3.13 |
| 17 | Display (DE, TCON, HDMI, DSI) | |
| 18 | Video engine, NPU | |

**Board and distributions:**
- the Zero 3W DTS, as soon as the `.dtsi` lands, then the Zero 4 DTS;
- the U-Boot Zero 3W board, after the A733 base;
- the meta-sunxi machine.

**Your merged or posted sunxi work so far** (patchwork, author Nguyen Minh Tien): hwspinlock D1, the `sun6i-dma` deadlock fix, the D1 CSIC driver + DT, the MUSB D+ pullup, the `drm/sun4i` DSI A100 mod clock, the OV3660 driver, and meta-sunxi PR #467. Tier 1 #4/#5 and Tier 2 #13 reuse exactly that experience.

**The Android farm runs alongside.** Its GPU route (Route M) depends on items 12 and 8–10 here, and on Imagination's BVNC and firmware upstreaming (farm README 16.16).
