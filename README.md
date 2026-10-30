# Avaota-A1 (Allwinner T527 / A527): JTAG and DRAM-training notes

Research notes for the YuzukiHD / Pine64 **Avaota-A1** board. They answer nine questions:

1. How do I enable JTAG on this chip? (Section 1)
2. Can I use this cheap board to learn DRAM (LPDDR4) training? (Section 2)
3. Would an NXP i.MX board be a better buy, and is DDR training in demand? (Sections 2.6 and 2.7)
4. How do the Avaota-A1, FRDM-IMX93 and FRDM-IMX95 Pro compare for DDR work, and does i.MX95 PHY-firmware reverse engineering carry over to the i.MX93? (Sections 2.16 and 2.17)
5. What can you learn about DRAM with T113-S3, RZ/V2L SMARC, Avaota-A1, FRDM-IMX93 and FRDM-IMX95 Pro together? (Section 2.18)
6. Which parts of this actually pay off for an embedded Linux BSP job target? (Section 2.19)
7. What does the Avaota-A1 add over your T113-S3 board, can the T527 do instruction trace like the i.MX95, how does the Orange Pi 4A (same T527) compare, what about the Orange Pi Zero 4 and Zero 3W (A733), and does JTAG work on the A733? (Section 3)
8. Who is mainlining the A733 right now, what can an Orange Pi Zero 3W owner contribute (Linux, U-Boot, SyterKit), and is there Yocto support? (Section 3.11)
9. What does the local FRDM-IMX95-PRO DRAM work show, and what is still closed? (Section 2.20)

When this was checked:
- **2026-10-22:** against the files in this repo (schematic v1.7, BOM v1.7, the Allwinner manuals) and against upstream source code (xfel, SyterKit, U-Boot and OpenOCD).
- **2026-10-28:** the A733 parts (3.8–3.11) were updated against the mainline trees, the mailing lists and the vendor binaries.
- **2026-10-28 (i.MX95 DRAM):** the FRDM-IMX95-PRO findings (§2.20) were checked against the local imx95 repo, the pinned imx-oei source (`e9bce6f4`), the Yocto deploy directory and the board's own documents. §2.6, §2.14 and §2.17 were corrected to match.

Nothing has been tried on a real board yet. Steps that depend on hardware behaviour are marked **(untested)**.

**Decision (2026-10-28):** the first A733 board is an **Orange Pi Zero 3W, 6 GB**, because the local shop has no Zero 4 6 GB. It will serve as:
- the redroid farm pilot ([3.a733-android-farm](3.a733-android-farm/README.md));
- the DDR study board ([4.a733-ddr](4.a733-ddr/README.md));
- the upstream board (3.11).

---

## 0. Board at a glance

| Item | Value | Where it comes from |
|---|---|---|
| SoC | **T527** on the BOM (part `U14`). Pine64 sells the board as "A527". Both chips are the sun55iw3 family, and the JTAG pin mux and GPIO registers are the same in the A527 and T527 manuals. | BOM v1.7, schematic sheet 4 |
| DRAM | 1× LPDDR4 FBGA200 chip (`UD1`), 32-bit bus | BOM v1.7, SyterKit DT |
| PMIC | AXP717 (`U4`) and AXP323 (`U5`) | BOM v1.7, schematic sheet 3 |
| Storage | microSD (SDC0 on PF0–PF6), eMMC (SDC2), SPI NAND W25N01GV (`U18`) | BOM v1.7 |
| Debug UART | UART0 on PB9/PB10, 40-pin header **pin 8 = TX, pin 10 = RX**, 3.3 V | schematic sheets 6 and 9 |
| FEL (USB recovery) | `FEL1` push-button | schematic sheet 4 |
| I/O voltage | VCC-IO and VCC-CARD both come from AXP717 CLDO3 at **3.3 V** | schematic sheet 3 |
| Price | Pine64 store, 4 GB/32 GB: "community price" **$54.95** (2 GB/16 GB: $39.95), without shipping | [pine64.com](https://pine64.com/?p=358314) |

Repo layout:

- [1.hardware/Avaota-A1](1.hardware/Avaota-A1): YuzukiHD open hardware. Contains schematics v1.2–v1.7, BOM, Gerbers, Altium/EasyEDA projects, LPDDR4 layout templates (`resource/dram_4l`, `resource/dram_8l`) and IBIS models.
- [2.docs/docs](2.docs/docs): Allwinner documentation: A523/A527/T527/A733/T736 manuals, hardware design guides and SDK guides.
- [4.a733-ddr](4.a733-ddr/README.md): A733 DRAM training, taken apart from Allwinner's own public binaries. It's the same Synopsys LPDDR5 PHY as the i.MX95. Covers the vendor save/restore of trained values, the standby retention list, crash-dump-to-FEL, and tools to step and snapshot training over JTAG or UART.
- [3.a733-android-farm](3.a733-android-farm/README.md): side project. Runs redroid (Android in Docker) on A733 boards (Orange Pi Zero 3W / Zero 4) with the PowerVR GPU. It has build scripts for the binder-enabled host kernel and for the Android-flavour GPU driver, plus static checks of the driver/blob pairing. Its sources and build outputs are re-fetched or rebuilt by its scripts and are not committed.

---

## 1. JTAG

### 1.1 Short answer

The microSD sniffer + CH347F setup used on the **T113** should work here without changes. On T527 the main-CPU JTAG sits on the same SD pins, in the same register (`PF_CFG0 @ 0x020000F0`), with the same function number (3).

There is one difference. **On Avaota-A1, nothing turns JTAG on by default.** You have to switch PF0/PF1/PF3/PF5 to function 3 yourself, and then stop anything else from switching them back to SD mode:

```
PF_CFG0 @ 0x020000F0  <=  0x0F3F3F33
        PF0=3 JTAG-MS(TMS)  PF1=3 JTAG-DI(TDI)  PF3=3 JTAG-DO(TDO)  PF5=3 JTAG-CK(TCK)
        PF2, PF4, PF6 = 0xF (I/O disabled)
```

`PF_CFG0` resets to `0x0FFF_FFFF` (all pins disabled). See A527 User Manual §8.6.6.45.

### 1.2 JTAG ports on the chip, and which ones the board wires out

| Port | Pins (mux function) | What it debugs | On Avaota-A1 |
|---|---|---|---|
| **CPUX JTAG** | PF0 TMS, PF1 TDI, PF3 TDO, PF5 TCK (func 3) | 8× Cortex-A55 | **microSD socket**: use this one |
| CPUX JTAG, alternate | PB0 TMS, PB1 TCK, PB2 TDO, PB3 TDI (func 4) | 8× Cortex-A55 | Only on the 50-pin RGB-LCD FPC (`FPC1`), pins 7/8/15/16 (LCD0-D0/D1/D8/D9). Needs a 0.5 mm FPC breakout. |
| S-RJTAG (T527 also has S-DJTAG) | PL8 TMS, PL9 TCK, PL10 TDO, PL11 TDI (RJTAG func 4; DJTAG func 3 on T527) | XuanTie E906 RISC-V (and the HiFi4 DSP on T527) | 40-pin header **pins 32, 31, 33, 36**. These pins are shared with the SPI-LCD nets (backlight enable, on-board SPI TFT). |
| S-JTAG | PL4–PL7 (func 2) | CPUS | Not connected |
| S-RJTAG, alternate | PM2–PM5 (func 3) | E906 | Only PM2/PM3 are wired (STWI1, header pins 28/29). PM4/PM5 are not connected, so this port is unusable. |

**The JTAG-SEL ball (G16)** is left floating on this board, and the internal pull-up makes it read 1. The A527/T527 hardware design guides define it as:

- `1` (default): software can route CPUX JTAG to **PF (default)** or PB.
- `0`: JTAG is forced onto PB.

The ball has no test pad, so leave it alone.

### 1.3 Wiring: microSD sniffer → CH347F

| microSD pin | SD signal | T527 pin | JTAG | CH347F |
|---|---|---|---|---|
| 1 | DAT2 | PF5 | **TCK** | TCK |
| 2 | CD/DAT3 | PF4 | (UART0-RX) | leave open |
| 3 | CMD | PF3 | **TDO** | TDO |
| 4 | VDD | VCC-CARD, 3.3 V | — | Reference only. Do not power the board from it. |
| 5 | CLK | PF2 | (UART0-TX) | leave open |
| 6 | VSS | GND | **GND** | GND |
| 7 | DAT0 | PF1 | **TDI** | TDI |
| 8 | DAT1 | PF0 | **TMS** | TMS |

- This is the same mapping as the linux-sunxi microSD breakout (DAT2→TCK, CMD→TDO, DAT0→TDI, DAT1→TMS). A sniffer wired for T113 fits as-is.
- Set the CH347F I/O to **3.3 V**.
- The SD slot carries no nTRST or nSRST. Leave CH347F **pin 8 (SRST)** unconnected, because the CH347F drives it low hard at power-up.
- For the console, use UART0 on header pins 8/10 rather than PF2/PF4. Muxing UART0 onto both PB9/PB10 and PF2/PF4 at once would give two inputs on one RX.

### 1.4 Why it "just works" on T113 but not here

- **xfel**: `xfel jtag` on T113 (`chips/r528_t113.c`) runs a small payload that sets PF0/1/3/5 to function 3 in `0x020000F0`. On the A523/A527/T527 family (`chips/a523_a527_t527.c`, xfel master 2026-09-14), `chip_jtag()` is an **empty stub that returns 0**, so `xfel jtag` does nothing. Use `xfel write32` instead (method A below).
- **Boot chain**: every boot-select option printed on schematic sheet 4 probes **SMHC0 (the SD slot) first**, so the BROM switches PF to SD mode while it probes. SyterKit (`mmc0_pins`: PF0–PF5, function 2), U-Boot and Linux also take PF0–PF5 for `mmc0`. On T113, your image or tooling had already put these pins in JTAG mode for you.
- **Correction, from your own T113 measurement:** elb1 field doc 07 §7 (2026-10-06) found that the T113 **boot ROM itself muxes the JTAG pins in FEL**, so no write was needed there. The T527 boot ROM may do the same.
  - **Check:** enter FEL and run `xfel read32 0x020000f0`. If PF0/1/3/5 already read function 3 (`…3?3?33`), attach directly; xfel's empty `chip_jtag()` may simply mean nothing is needed.
  - **If not,** use method A below.

### 1.5 Five ways to turn it on

**A. FEL mode.** No software changes. This is the best method for bring-up, and for stepping through your own SPL or DRAM-init code. **(untested)**

```sh
# Hold FEL1 and power on (or press reset), with the USB OTG port connected to the PC
xfel version                          # family ID is 0x00189000 (A523/A527/T527)
xfel write32 0x020000f0 0x0f3f3f33
xfel read32  0x020000f0               # expect 0x0f3f3f33
openocd -f avaota-a1-ch347.cfg        # see 1.6
```

In FEL mode the A55 runs the BROM in AArch32 state. Code you later load with `xfel write` + `xfel exec` keeps JTAG only as long as it does not re-mux PF.

**B. Vendor BSP boot0** (Tina / AIoT Linux SDK). Add this to `sys_config.fex`:

```ini
[jtag_para]
jtag_enable = 1
jtag_ms = port:PF00<3><default><default><default>
jtag_ck = port:PF05<3><default><default><default>
jtag_do = port:PF03<3><default><default><default>
jtag_di = port:PF01<3><default><default><default>
```

`update_boot0` copies these values into the boot0 header. In the boot0 main flow, `enable_jtag → boot_set_gpio` runs **before `init_DRAM`** (Linux_SPL-PUB guide §5.1), so JTAG is already live while libdram trains the DRAM. The Tina config guide (§3.2.10) uses PB14–PB17 in its example. On T527, use the PF pins shown above.

You must boot from eMMC with this method. U-Boot and Linux will still claim `mmc0` later, so either disable it or use method D.

**C. SyterKit or mainline U-Boot SPL.** Add one read-modify-write early in board init:

```c
/* PF0/PF1/PF3/PF5 -> JTAG (function 3); leave PF2/PF4/PF6 untouched */
u32 v = readl(0x020000f0);
v &= ~0x00f0f0ff;
v |=  0x00303033;
writel(v, 0x020000f0);
```

Also disable `mmc0` in that build and boot from eMMC.

**D. From a running Linux system.** Use this to attach to a live kernel. **(untested)**

```sh
# Release PF0-PF5 from the SD driver. The device name is 4020000.mmc (mainline)
# or 4020000.sdmmc (BSP); check under /sys/bus/platform/drivers/sunxi-mmc/
echo 4020000.mmc > /sys/bus/platform/drivers/sunxi-mmc/unbind
devmem 0x020000f0 32 0x0f3f3f33
```

Boot the kernel with `cpuidle.off=1`. Otherwise idle A55 cores power down and drop the debug session.

**E. The alternate PB route.** **(untested)** This is the **same CPUX debug port** (same DAP, same 8× A55, same OpenOCD config). Only the pins differ. Use it when you want to keep the SD slot free, for example to boot from SD while debugging.

- **Pins:** PB0–PB3 with mux function **4** (not 3). They are only wired to the 50-pin RGB-LCD connector `FPC1` (0.5 mm pitch), so you need an FPC breakout board.

  | FPC1 pin | Net | T527 pin | JTAG |
  |---|---|---|---|
  | 7 | LCD0-D0 | PB0 | TMS |
  | 8 | LCD0-D1 | PB1 | TCK |
  | 15 | LCD0-D8 | PB2 | TDO |
  | 16 | LCD0-D9 | PB3 | TDI |
  | 5, 6 (also 31, 39, 44, 50) | GND | — | GND |
  | 3, 4 | VCC-3V3 | — | I/O reference |

- **Enable it:** `PB_CFG0` is at `0x02000030` (reset value `0xFFFF_FFFF`). Set its low 16 bits to `0x4444`. From FEL: `xfel write32 0x02000030 0xffff4444`. In code: `v = readl(0x02000030); v = (v & ~0xffff) | 0x4444; writel(v, 0x02000030);`
- **Use one route at a time.** Leave PF0–PF5 out of function 3 while you use PB. JTAG-SEL is high on this board, which the design guide describes as "software selects PF or PB". I found no register for this other than the pin mux, so treat it as untested.
- **Costs:** the RGB LCD can't be used at the same time, and the FPC breakout is fiddlier to wire than an SD sniffer.

### 1.6 OpenOCD

- The **CH347 driver** has been in OpenOCD master since **2025-08-24**. It is not in any tagged release (the last tag is v0.12.0, January 2023), so **build OpenOCD from git**. The CH347F is auto-detected (VID `0x1a86`, PID `0x55de`).
- There is **no upstream T527/A523 target config**. The closest templates are `tcl/target/allwinner_h618.cfg` (4× A53, `aarch64`) and `tcl/target/rk3588.cfg` (DynamIQ A55 + A76).
- On T113 you used a Cortex-A7 (`cortex_a` target). This chip needs `aarch64` targets with per-core `-dbgbase` / `-cti` addresses, which you read from the ROM table.

Starter config **(untested)**:

```tcl
# avaota-a1-ch347.cfg: starting point, not yet tested on hardware
adapter driver ch347
transport select jtag
adapter speed 1000

# The ARM JTAG-DP IR length is 4. Add -expected-id <idcode> once you have seen the IDCODE.
jtag newtap t527 cpu -irlen 4
dap create t527.dap -chain-position t527.cpu
```

Discovery run:

```sh
openocd -f avaota-a1-ch347.cfg -c init -c "dap init" -c "dap info 0" -c "dap info 1"
```

Take the per-core **Debug** and **CTI** base addresses from the ROM table output. Then add one block per core, modelled on `allwinner_h618.cfg`:

```tcl
cti create t527.cti0 -dap t527.dap -ap-num <AP> -baseaddr <CTI0_BASE>
target create t527.cpu0 aarch64 -dap t527.dap -ap-num <AP> -dbgbase <DBG0_BASE> -cti t527.cti0
```

The A527 manual's CPUX block diagram labels the debug block "Coresight600". If `dap info` fails with ADIv5 errors, try `dap create ... -adiv6`.

### 1.7 Gotchas

- **The SD slot becomes the debug port**, so boot from eMMC (or SPI NAND). With the sniffer inserted, the BROM probes SD first, gets no reply, and falls back.
- **Anything that touches `mmc0` re-muxes PF0–PF5 and JTAG drops.** That includes the BROM, the boot0 card probe, U-Boot `mmc rescan` and Linux card-detect.
- **Idle A55 cores power down** and kill the session. Boot Linux with `cpuidle.off=1`.
- **eFuse**: the Allwinner SDK has `sid_disable_jtag()` (permanent, secure-boot flow only) and secure-debug certificates (A527 UM §9.1.4). Setting `jtag_enable = 0` in `sys_config.fex` only stops boot0 from setting the pins. Retail Avaota boards boot unsigned SyterKit/U-Boot, so the secure-boot fuses (including JTAG-disable) are normally not burned. If `scan_chain` finds nothing after the mux write, check wiring and voltage levels first.
- **Speed**: start at 1 MHz and raise it once the chain is stable. Sniffer flex cables are long.
- The PB route conflicts with an RGB LCD. The PL route conflicts with the SPI-LCD / backlight nets.

---

## 2. Can I learn DRAM training on Avaota-A1?

### 2.1 Verdict

**Yes, for the firmware side of LPDDR4 bring-up and training. No, for PHY internals or signal integrity.**

What makes it a good learning board:

1. **Open-source DRAM init for this exact board.** Mainline U-Boot has `arch/arm/mach-sunxi/dram_sun55i_a523.c` (about 1,500 lines, LPDDR4 + DDR3, merged July 2025) and `configs/avaota-a1_defconfig`. The code is reverse-engineered, but it is readable C that you can modify and rebuild in minutes.
2. **The vendor training is observable.** Allwinner's libdram "soft training" logs per-byte and per-bit eye scans (range / width / center). The guide is in this repo.
3. **It cannot be bricked.** USB FEL lives in the BROM and the `FEL1` button is on the board. Bad DRAM parameters only make the boot fail, and you can recover with `xfel`.
4. **JTAG works before DRAM is up.** The SPL runs from SRAM, so you can halt in the middle of training (Section 1).
5. **The DRAM rail is adjustable.** VCC-DRAM comes from AXP717 DCDC3, which the schematic marks "软件调整" (software-adjusted); mainline sets it to 1160 mV. This allows voltage margining.
6. **The hardware is open.** Schematic, PCB, LPDDR4 layout templates (4-layer and 8-layer) and T527 LPDDR4/4X IBIS models are all available, so you can relate layout to training results.

What limits it:

1. **There are no register docs.** The DRAMC chapter of the A527/T527 user manual (§3.2) is a one-page feature list. `MEMC_DDRC` (`0x0313_0000`) and `MEMC_PHY` (`0x0314_0000`) are undocumented, and the mainline code is full of magic offsets (`//TODO: ???`).
2. **Most training runs in hardware engines inside the PHY.** Software sets bits and polls for write leveling, read-gate calibration and read/write training. You learn the sequence and the results, not the engine's algorithm.
3. **Allwinner's software eye-scan training is a closed blob** (`libdram`): BSP boot0, SyterKit's `soc/sun55iw3/lib/libdram.a`, and xfel's `xfel ddr lpddr4` payload. It is **reversible**, though: see 2.9.
4. **The mainline driver has no command-bus-training step.** CA timing comes from fixed per-bit delays.
5. **One soldered x32 LPDDR4 chip, and no DQ/DQS test points.** You cannot scope eyes (and that would need a multi-GHz scope anyway).

### 2.2 DRAM setup on this board

| | |
|---|---|
| Memory | 1× LPDDR4, FBGA200, x32. One rank on the 4 GB board, auto-detected by both stacks. |
| Controller limits (UM §3.2) | 32-bit DDR3/DDR3L/DDR4/LPDDR3/LPDDR4/LPDDR4X, up to 4 GB, up to 1200 MHz for LPDDR4 |
| Clock used | **1200 MHz** (≈ LPDDR4-2400) in the SyterKit DT and as the U-Boot default for A523 |
| Rails | VCC-DRAM = AXP717 DCDC3 (adjustable); VDD18-DRAM = ALDO4 1.8 V |
| Parameter-select straps | DDR-PARA-SEL-ADC1/2 on GPADC1/GPADC2 (sheet 4). They let one firmware pick between DRAM parameter sets. |

Board parameters, from SyterKit `boards/avaota-a1/board.dts` (U-Boot `avaota-a1_defconfig` uses the same ODT, drive and TPR values):

| Field | Value | Meaning |
|---|---|---|
| `dram_clk` | `1200` | MHz |
| `dram_type` | `8` | LPDDR4 |
| `dx_odt` / `dx_dri` / `ca_dri` | `0x07070707` / `0x0d0d0d0d` / `0x0e0e` | Per-byte ODT and drive strength, CA drive strength |
| `para0` | `0x84848484` | Allwinner's training log prints it as **write DQS**. U-Boot calls it `ODT_EN`. |
| `mr14` | `0x08` | LPDDR4 MR14 (write Vref) |
| `tpr6` | `0x38000000` | Read Vref |
| `tpr10` | `0x802f3333` | Feature bits. U-Boot names: bit 20 write leveling, bit 21 read calibration, bit 22 read training, bit 23 write training, bits 17/18 DQ bit-delay. Only **read calibration and bit-delay** are enabled here. |
| `tpr11` | `0xc7c5c4c2` | Write DQ delay, one byte per lane |
| `tpr12` | `0x3533302f` | Read DQ delay, one byte per lane |
| `tpr13` | `0x860` | Bit 11 = Allwinner soft DQ eye training **on**. Bit 10 = per-bit training **off**. |
| `tpr14` | `0x48484848` | Read DQS delay |

### 2.3 The three software stacks

1. **Allwinner BSP boot0 + libdram (closed).** Parameters live in `[dram_para]` in `sys_config.fex`. Soft training ("眼图自适应", which needs T527 libdram ≥ V0.67) is controlled by `tpr13`: bit 11 runs a per-byte DQ eye scan, and bit 10 adds a per-bit scan. Excerpts from the example log in the guide:
   ```
   [SOFT TRAINING] Dbyte0 rdq 1st dqs_move:0,range: 36~68,width=36,center=0x34
   [SOFT TRAINING] rdq00 move:0,range: 27~71,width=45,center=0x31
   [SOFT TRAINING] rVREF:tpr6=0x3a000000 wVREF:mr14=0x0000000e
   [SOFT TRAINING] rDQ: tpr12=0x38353234 wDQ: tpr11=0xd7d6d6d7
   ```
   Allwinner's rules of thumb:
   - Eye width **< 32** steps means small margin. Width **< 24** points to a likely performance problem.
   - To get fixed parameters, train 5–8 boards and take the middle value.
   - Training runs once, at first boot or during USB flashing, and the result is written back to flash.
   - Production firmware does not print the detailed log. Allwinner's DragonHD tool (Windows, in APST) shows it.
2. **SyterKit** (YuzukiHD). It uses the same libdram blob, but the parameters live in a small DT and the build is fast. This is the easiest place to flip `tpr13` bits and read the boot log.
3. **Mainline U-Boot SPL (open source).** The flow:
   1. `mctl_sys_init`: sets PLL5 to 2× the DRAM clock and handles resets.
   2. Detects rank, width and size at 360 MHz with safe delays.
   3. Re-initialises at `CONFIG_DRAM_CLK`:
      - `mctl_ctrl_init`: DesignWare-style controller, with helpers shared with H6/H616.
      - `mctl_phy_init`.
      - `mctl_phy_write_leveling`, `mctl_phy_read_calibration`, `mctl_phy_read_training` and `mctl_phy_write_training`, each gated by its TPR10 bit.
      - `mctl_phy_bit_delay_compensation`, using `tpr11`/`tpr12`.

   Read and write training read the left/right eye-edge registers of each lane (for example PHY `+0x850` vs `+0x898`, nine entries per group). Training fails if any window is ≤ 6 taps. **That check is a good place to add a `printf` and get your own per-bit eye report.**

### 2.4 Suggested exercises

1. Read `dram_sun55i_a523.c` next to the JEDEC LPDDR4 spec (JESD209-4) init and training sequence, and annotate every step.
2. Build U-Boot `avaota-a1_defconfig`. Print the eye-edge registers, then turn on TPR10 bits 20/22/23 (hardware write leveling, read training, write training) and compare the results with the fixed `tpr11`/`tpr12`.
3. Run a **shmoo**: sweep `CONFIG_DRAM_CLK` (Allwinner steps in 24 MHz), ODT, drive strength and Vref. Test each point with U-Boot `mtest`, Linux `memtester` or `stressapptest`, and plot pass/fail. Allwinner's own margin test runs DRAM **48 MHz above** the production frequency.
4. **Voltage margining** with AXP717 DCDC3. Stay inside the LPDDR4 VDD2/VDDQ operating range (1.06–1.17 V).
5. Set `tpr13` bit 10 in SyterKit and compare the vendor's per-bit eye widths with what the mainline training finds.
6. Use **JTAG**: halt the SPL during training and change PHY delay registers live. Also dump `0x0313_0000` / `0x0314_0000` after the vendor blob finishes and diff them against mainline; this is how the mainline driver was reverse-engineered.
7. Look at the SI side: open the LPDDR4 layout templates ([resource/dram_4l](1.hardware/Avaota-A1/resource/dram_4l), [resource/dram_8l](1.hardware/Avaota-A1/resource/dram_8l)) and the [T527 LPDDR4 IBIS model](<2.docs/docs/T527/Hardware硬件类文档/硬件设计/IBIS模型/t527_lpddr4_allwinner.ibs>) to see why the lanes train to different delays.

### 2.5 Price and value

Pine64 lists the 4 GB / 32 GB board at **$54.95** (checked 2026-10-22). The ~$75 figure probably includes shipping or comes from another store. For that money you get an LPDDR4 x32 platform with an open-source DRAM driver, FEL recovery and JTAG, which is very good value for learning.

I picked this board because it is cheap. Section 2.6 checks whether an NXP i.MX board would be a better buy, and section 2.7 looks at whether DDR training is worth learning for the job market.

### 2.6 Avaota-A1 vs NXP i.MX and other cheap boards

**What NXP offers.** The NXP DDR tool is part of Config Tools for i.MX (a download that needs an NXP account). It is the standard workflow for i.MX board bring-up:

- Generate the DDR configuration for your board.
- Load a test image into on-chip RAM over USB. No flash or OS is needed.
- Run training ("Firmware Init").
- Run stress tests, including overnight runs.
- Sweep ODT and Vref for DQ and CA.
- Draw **virtual eye diagrams** (vTSA): RX/TX data eye, CA bus margin and CA eye, for LPDDR4.

NXP lists support for i.MX 8M, 91, 93, 95, 943, 93W and 952. This is the tool employers expect you to know for i.MX boards.

**What NXP does not offer either:**

- The training itself is Synopsys DDR PHY firmware (the PMU binaries `lpddr4_pmu_train_*` in `firmware-imx`). NXP says the source is not available, not even to its customers.
- U-Boot's `drivers/ddr/imx/imx8m/ddrphy_train.c` only loads that firmware, writes the message block, runs the PMU and reads back the result.
- The reference manuals document the DDR controller but not the PHY. For example, the i.MX95 RM has chapter 114 DDRC with 122 register descriptions, but no PHY register chapter.

**So the two boards teach different things.**

- **NXP**: the industrial validation workflow, with polished visibility (eyes, margins, stress results).
- **Avaota-A1**: what the init code actually does, with source code and JTAG.
- Neither shows how the PHY's training engine works inside.

Prices below were checked 2026-10-22. They are distributor snapshots and are not like-for-like on tax.

| Board | SoC / CPU | DRAM | Price | DDR tooling | Open training code |
|---|---|---|---|---|---|
| **Avaota-A1 4 GB** | T527, 8× A55 | LPDDR4 x32, 4 GB | **$54.95** (Pine64) | Allwinner DragonHD (Windows) + libdram soft-training logs | **Yes**: mainline U-Boot (reverse-engineered) |
| FRDM-IMX91S | i.MX91, 1× A55 1.4 GHz | LPDDR4, 512 MB | ~US$51 / €41.25 ex VAT (Farnell) | NXP DDR tool | U-Boot + Synopsys firmware blob |
| FRDM-IMX91 | i.MX91, 1× A55 1.4 GHz | LPDDR4, 1 GB | ~S$108 / AU$120 ex GST (element14) | NXP DDR tool | same as above |
| **FRDM-IMX93** (already owned) | i.MX93, 2× A55 1.7 GHz + M33 + NPU | LPDDR4X, 2 GB | ~$71–74 (Future), €69–71 (DigiKey) | NXP DDR tool | same as above |
| MaaXBoard Mini | i.MX8M Mini, 4× A53 | LPDDR4 | $72.50 at launch (2020); now $149.95 with 0 stock (Avnet), €133 (Farnell) | NXP DDR tool (most mature target) | same as above |
| FRDM-IMX8MPLUS | i.MX8M Plus, 4× A53 + NPU | LPDDR4 | ~$100–115 | NXP DDR tool | same as above |
| **FRDM-IMX95-PRO** (already owned) | i.MX95, 6× A55 | LPDDR5 x32, 16 GB (Micron MT62F4G32D8DV-023FAIT, UM12527) | already paid | NXP DDR tool lists i.MX95 | **Partly**: open imx-oei (BSD-3); the training firmware is a closed binary (§2.20) |
| PocketBeagle 2 | TI AM6254, 4× A53 | 512 MB (LPDDR4 per CNX; one forum post says DDR4) | ~$29 | TI SysConfig DDR config + DDR-MARGIN-FW | **Yes**: U-Boot `k3-ddrss` (Cadence driver) |
| STM32MP135F-DK | STM32MP135, 1× A7 | DDR3L x16, 512 MB, 533 MHz | ~€128 ex VAT (RS Italy) | CubeMX DDR test suite | **Yes**: software DQS gating, bit deskew and eye training in U-Boot SPL |

**The two NXP chips you asked about:**

- **i.MX8M Mini: skip it.** There is no cheap board any more. It is the most mature DDR-tool target, but the same tool runs on the newer and cheaper FRDM boards.
- **i.MX91: the cheapest NXP DDR-tool target you can own** (FRDM-IMX91S, ~$51). The single A55 is weak, but CPU speed does not matter for DDR work. It has a 16-bit DRAM bus (2 byte lanes, vs 4 on Avaota-A1 and i.MX95), so there is less lane-to-lane variation to study.

**You already own both FRDM-IMX93 and FRDM-IMX95 Pro, so the NXP side is covered. Don't buy more NXP boards.**

- The DDR tool runs its test image from on-chip RAM over USB and does not touch the eMMC. You can learn the NXP workflow on either board for free.
- The FRDM-IMX93 is the safer DDR-tool target. vTSA is listed for LPDDR4, and i.MX93 is a mature tool target.
- On the FRDM-IMX95-PRO, check inside the tool whether it has a board config for it and whether vTSA works on i.MX95. I could not confirm either from NXP's page, and I have not checked the board documents for them (§2.20 lists what is open).

**The only purchase left is the Avaota-A1.** It has FEL recovery, so DRAM experiments can't brick it, and it is easy to order.

**Two non-NXP options:**

- **TI PocketBeagle 2** (~$29) is the cheapest board with a vendor DDR flow.
  - TI's SysConfig DDR tool lists IO calibration, command-bus training, write leveling, read gate, read leveling and Vref training.
  - DDR-MARGIN-FW does a 2D Vref × delay sweep and draws a virtual eye. It supports LPDDR4 only, and loads over CCS/JTAG or UART boot.
  - The U-Boot `k3-ddrss` driver is open source.
  - Downsides: forum reports say the margin firmware is fiddly outside TI EVMs, and the memory type needs confirming first (LPDDR4 vs DDR4).
- **STM32MP135F-DK** (~€128) is the most transparent platform for training *algorithms*.
  - In U-Boot SPL's DDR interactive mode, DQS gating, bit deskew and eye training run in **software** (`stm32mp1_tuning.c`).
  - The PHY delay registers (DXnDQTR, DXnDQSTR) are used by name in public code.
  - Downsides: old DDR3L, a slow single A7, and twice the price.
- An FPGA board running LiteDRAM is the fully open option (controller, PHY and software leveling). It costs more and runs at DDR3 speeds.

**Plan:**

1. Buy the **Avaota-A1** and make it the main DRAM board: cheap, strong, open code, JTAG, FEL.
2. Learn the **NXP DDR tool on the FRDM-IMX93 / FRDM-IMX95** you already have. Use its vTSA eye output as the reference for what your own Avaota eye scan should look like (section 2.10).
3. Add a PocketBeagle 2 later if you want a second vendor's (TI) workflow to compare.

### 2.7 Is DDR training worth learning for the job market?

There are two different markets.

**1. DDR / memory PHY firmware engineer at chip companies.** This is the "training" job proper. It is real and well paid, but small.

Postings found in October 2026:
- AMD Memory PHY Firmware Engineer, Austin: DDR PHY + DRAM training steps + lab bring-up, $90k–130k.
- AMD MTS, Bengaluru: DDR/LPDDR/HBM training algorithms.
- Intel DDR PHY Firmware, Guadalajara: write/read leveling, Vref training, JEDEC; 5+ years.
- Cadence principal firmware engineer for DDR5 PHY microcontrollers.
- Astera Labs: DDR firmware for CXL memory products.
- Qualcomm DDR PHY system design, San Diego: $140k–210k, leaning towards signal and power integrity.

What these postings ask for, and where they are:
- **Typical requirements:** EE/CE degree, JEDEC specs, C and Python, often Verilog/SystemVerilog simulation, post-silicon lab work, 5+ years.
- **Location:** almost all US, India or Mexico. A quick search found none in the Netherlands, Germany or Romania, though that does not prove there are none.
- **Tailwind:** the AI-driven memory crunch (HBM, LPDDR5X, LPDDR6, SOCAMM, CXL) adds memory complexity and investment. This is my inference from market reports, not from job counts.
- **Limit of a hobby board:** it gives you the vocabulary and the flow. The real job happens on pre-production silicon, with PHY databooks and lab equipment.

**2. DDR bring-up as part of embedded board bring-up.** There are far more of these jobs, but here DDR is a line on a CV rather than a job title. Every custom i.MX, TI or STM32MP board needs the same steps:
- the vendor DDR tool configuration,
- training, stress and margin checks,
- working with the layout engineer when it fails.

**What this means for you:**

- **As an add-on to your embedded Linux / i.MX path: worth it, and cheap.** A few weeks gets you to "I can bring up and validate DDR on a custom i.MX board with the NXP DDR tool, and I understand what training does underneath". That is a real differentiator in board bring-up interviews.
- **As a career switch: a narrow niche.** It is centred on the US and Asia, expects chip-company experience, and would compete with the camera/ISP roadmap for your time. Timebox it (for example 4–6 weeks) unless you decide to target memory-firmware roles at AMD, Intel or Qualcomm-type companies.

### 2.8 Swapping the DRAM chip: how hard is it?

**The hardware part is the hard and risky part. The software part is easy, as long as the new chip is the same type.**

**What fits** (schematic sheet 5, BOM v1.7):

- **Package:** a 200-ball LPDDR4 FBGA (footprint `BGA200P65_80B1000_1500H90`: 0.65 × 0.80 mm pitch, 10 × 15 mm). It is an x32 part with 2 channels of 16 bits. CS0 and CS1 are both wired, so 1-rank and 2-rank parts work. The controller limit is **4 GB**.
- **LPDDR4 only, not LPDDR4X.**
  - The board ties the DRAM's VDD2 and VDDQ and the SoC's PHY I/O rail (VCC-DRAML) together on VCC-DRAM, at **1.1 V**.
  - The schematic note says LPDDR4X needs VCC-DRAML from a separate DC-DC converter at 0.6 V, which this board does not have.
  - A part rated only for LPDDR4X would therefore run out of spec. Choose a part whose datasheet supports LPDDR4 at VDDQ = 1.1 V.
- **Candidates:** [A523 DRAM support list V1.3](<2.docs/docs/A523/Hardware硬件类文档/硬件物料清单/Allwinnertech A523 DRAM Support List V1.3.xls>) in this repo. Confirm the package and voltage of each part in its datasheet.
  - CXMT: CXDB3ABAM-MK-A, CXDB5CCBM-MJ-A, CXDBBCCBM-MK-B
  - FORESEE: FLXC2004G-30 / -N1
  - Nanya: NT6AN512T32AV-J2, NT6AN1024F32AV-J2
  - Rayson: RS512M32LM4D2BDS-53BT, RS1G32LV4D2BDS-53BT
  - SK hynix: H9HCNNNBKUMLXR-NEX (listed as both LPDDR4 and LPDDR4X)
  - KALXX4S43AY2-T40 (vendor not given)
- **The original chip** on the 4 GB board is not named in the BOM (it just says `LPDDR4_FBGA200`). Read the marking on yours.

**Difficulty, step by step:**

| Step | Difficulty | Notes |
|---|---|---|
| Remove the old chip, clean the pads, place the new one | **Hard** | Fine-pitch BGA rework needs hot air plus a bottom preheater, flux and a steady hand. The DRAM sits next to the T527 and the eMMC, so too much heat can kill them. Expect to lose a board or two while learning, or pay a phone-repair shop (they do LPDDR rework all the time). New chips come pre-balled. |
| First boot | Easy | The FEL button and USB still work whatever the DRAM state, so a failed DRAM init cannot brick the board. |
| Vendor libdram | Easy | Rank, width and size are auto-detected (`[AUTO DEBUG]32bit,2 ranks training success!`). The eye-adaptive guide says "one template, one parameter set: new parts of the same type need no new parameters", with soft training on (`tpr13` bit 11). |
| Mainline U-Boot | Easy–moderate | Rank, width and size are also auto-detected, but the timings in `dram_timings/a523_lpddr4.c` are fixed. For example tRFC is 280 ns, tRAS 42 ns and tRC 65 ns. Check them against the new part's datasheet (tRFCab, speed bin). |
| Validation | Moderate (time) | Check the soft-training eye widths (≥ 32 good, < 24 bad), then run U-Boot `mtest`, `memtester` or `stressapptest`, reboot loops and suspend/resume (self-refresh). Repeat warm and cold. |

**Cheaper first step without soldering:** buy the **2 GB / 16 GB board ($39.95) next to the 4 GB one**. You get a second chip and a different density and rank setup, so you can compare training results, eye widths and margins before touching a hot-air gun.

### 2.9 Reversing libdram

The blob is a good reverse-engineering target. SyterKit's `soc/sun55iw3/lib/libdram.a`:

- is a 32-bit ARM relocatable object (about 43 KB),
- is **not stripped**, so all **66 functions keep their names**,
- has its log strings intact (`Soft Training Version: %s`, `read dx%d_dq%d delay_width_error`, `[AUTO DEBUG]…`).

Largest functions, in bytes:

| Function | Size | What it probably is |
|---|---|---|
| `mctl_phy_dx_bit_delay_compensation` | 2778 | Per-bit DQ delays (`tpr11`/`tpr12`) |
| `mctl_mdfs_init` | 2520 | Multi-frequency (DVFS) setup |
| `mctl_com_set_channel_timing` | 2424 | Controller timings |
| **`dst_dq_eye_scan`** | **1984** | **The soft-training eye scan: the algorithm you want** |
| `phy_read_training` / `phy_write_training` | 1236 / 1072 | Kicks the hardware training engines |
| **`dx_training`** | **892** | **Soft-training driver** |
| `auto_scan_dram_config` / `_size` / `_rank_width` | 572 / 452 / 388 | Auto-detection |
| `dst_dramc_memtester_test`, `mctl_neon_*` | — | NEON memory tests used as the pass/fail check |

**What this means:**

- The hardware-training functions (`phy_write_leveling`, `phy_read_calibration`, `phy_read/write_training`) match the mainline U-Boot functions one for one, so that part is already reversed. `mctl_phy_write_leveling` and the others in `dram_sun55i_a523.c` follow the same structure.
- What is still closed is the **software training** (`dst_dq_eye_scan`, `dx_training`, `Get_rx_vref_value`) and MDFS. That code sweeps PHY delay and Vref registers and runs memory tests in plain ARM code. **Reversing it gives you a complete, real-world eye-scan training algorithm.** That is more than either the hardware engines here or NXP's Synopsys firmware will ever show you.
- **Effort:** with Ghidra and symbols, about 3–4 KB of soft-training code is a few weeks of evenings.
- **Legal:** EU law allows decompiling for interoperability. To publish, do what the mainline driver did: write your own notes and code, and don't post decompiled output.

### 2.10 Filling the missing register documentation

Reversing `dst_dq_eye_scan` gives you the **control flow**: loops, compare logic, how the eye center is picked. What's missing is the **meaning of the registers** it touches. The mainline H616 driver has the same problem and says so: *"PHY is completely unknown … Some meaning was nevertheless deduced from strings found in boot0 and known meaning of some dram parameters."*

Split the problem into four layers. Each one has a different source.

| Layer | Where | Status | What fills it |
|---|---|---|---|
| **DRAM chip** (mode registers MR1–MR22: ODT, drive, Vref, latency; training commands) | Inside the LPDDR4 chip | **Fully documented** | JEDEC JESD209-4 (free with a JEDEC account) and any LPDDR4 vendor datasheet (Micron MT53, Nanya NT6AN, …) |
| **Memory controller** (`MEMC_DDRC`, `0x0313_0000`) | T527 | **Documented elsewhere** | It is a Synopsys DesignWare **uMCTL2**. Mainline's `struct sunxi_mctl_ctl_reg` uses uMCTL2 names at uMCTL2 offsets (MSTR `0x000`, PWRCTL `0x030`, RFSHTMG `0x064`, DRAMTMG `0x100`, ZQCTL `0x180`, DFITMG `0x190`, ADDRMAP `0x200`, SWCTL `0x320`). The same IP is documented bit by bit in the **i.MX 8M Mini/Plus RM** (DDRC chapter; free with your NXP account), **AMD/Xilinx UG1087** (Zynq UltraScale+ register reference, `DDRC` module, public) and **ST RM0436** (STM32MP15 `DDRCTRL`). Cross-check fields against mainline, because versions differ. Note that i.MX93/95 use a different NXP controller, so their RMs don't help here. |
| **Controller ↔ PHY interface** (DFI timings: `dfitmg*`, `dfiupd*`, `dfimisc`) | Between them | **Documented** | The DFI specification (from ddr-phy.org) |
| **PHY** (`MEMC_PHY`, `0x0314_0000`): delay lines, Vref, training engines, eye-edge results | T527 | **Undocumented**, Allwinner's own PHY | Fill it in yourself, using the steps below |

**How to fill the PHY layer:**

1. **Start from known names.**
   - The mainline A523 driver uses 209 distinct PHY offsets. **78 of them also appear in the H616/H618 driver**, so it is the same PHY family, and the earlier drivers' comments and structure carry over.
   - Allwinner's eye-adaptive guide gives the parameter meanings: `tpr11` = write-DQ delay, `tpr12` = read-DQ delay, `tpr14` = read-DQS, `para0` = write-DQS, `tpr6` = read Vref, `mr14` = write Vref, `tpr13` bits 10/11 = soft training, plus the TPR10 bits in mainline.
   - The blob's log strings (`read dx%d_dq%d delay_width_error`, `dx_low 16bit read training error`) label the registers read right next to them.
   - The full parameter reference, *T527_DRAM 配置参数说明 V1.5*, is cited by the eye guide but is not in this repo. Ask Allwinner, or look for it in SDK dumps.
2. **Trace the data flow in Ghidra.** Follow each known parameter (for example `tpr12` byte 0) from `init_DRAM`'s argument to the `str` that writes it into a PHY register. That register field is then "read DQ delay, lane 0". This is how most of mainline was named.
3. **Black-box mapping with FEL (no JTAG needed).** Load a SyterKit DRAM-init app with xfel, change one parameter by one step, re-init, and dump `0x0314_0000`–`0x0314_0FFF` (and the DDRC). Diff against the previous dump. Each diff names one register field. A script can run hundreds of these loops unattended, and FEL guarantees the board always comes back.
4. **Call the blob's own functions.** Its symbols are global, so a SyterKit app can call `dst_dq_eye_scan()`, `phy_read_training()` and the others directly, once you have reversed their prototypes. You can then run them with your own inputs and log the results (a "harness").
5. **Catch writers with JTAG.** Put an A55 hardware watchpoint on one PHY register address to see exactly which blob function writes it, and with which value.
6. **Measure what the docs would have told you.**
   - **Tap size:** sweep a read-delay field while reading a known pattern. The number of taps it takes for the data to shift by one bit equals one UI. At 1200 MHz (2400 MT/s) one UI is about 417 ps, so ps/tap = 417 / taps.
   - **Vref steps:** sweep the Vref field until the eye closes at the top and bottom. Compare against the JEDEC MR14 Vref table for the DRAM side.
7. **Use your NXP boards as the reference.** Run vTSA on the FRDM-IMX93 to see what a correct delay × Vref pass/fail grid looks like. Rebuild the same grid on Avaota from your reversed `dst_dq_eye_scan` and the fields you mapped. If both look alike, your understanding is right.

**What stays unknown even after all this:** what happens *inside* the PHY's hardware training engines (write leveling, gate, read/write training), and absolute analog details beyond what you can measure. Everything the software eye scan does is recoverable.

### 2.11 Avaota-A1 vs FRDM-IMX93: same RAM, different PHY?

A DRAM subsystem has three parts, and only the last one is common between the two boards:

```
CPU cores ── interconnect ── [ memory controller ] ──DFI── [ PHY ] ═══ PCB ═══ [ LPDDR4(X) chip ]
                               scheduling, timings,          I/O pads, delay      JEDEC protocol,
                               refresh, address map          lines, Vref, ODT,    mode registers,
                                                             training logic       no CPU inside
```

| | Avaota-A1 (T527) | FRDM-IMX93 |
|---|---|---|
| DRAM chip | LPDDR4 x32 (2 × 16-bit channels), VDDQ **1.1 V** | Micron **MT53E1G16D1FW-046 AAT:A**, **x16** single channel, 2 GB (UM12181). The part supports both LPDDR4 and LPDDR4X modes (NXP compatibility guide). The board runs it as LPDDR4X (U-Boot uses `lpddr4x_*_timing.c`), so VDDQ is **0.6 V**. |
| Controller | Synopsys uMCTL2-style (see 2.10) | NXP DDRC |
| PHY | Allwinner's own PHY with fixed hardware training engines (state machines). Mainline drives everything with register writes and polling, and shows no sign of a processor inside. | Synopsys DWC LPDDR4/4X PHY with an embedded **microcontroller (PMU)** |
| Who runs training | The **A55 CPU**. boot0/libdram or U-Boot SPL starts the hardware engines, then runs the software eye scan (`dst_dq_eye_scan`) itself. | The **PMU inside the PHY** runs Synopsys training firmware (`lpddr4*_pmu_train_*` / `*_imem_*` binaries). U-Boot only loads it and reads back the result message block. |
| Step through it with JTAG? | Yes, it's A55 code | No, it runs inside the PHY |

**Same RAM chip on both boards? Not in practice.**

- **Width:** the i.MX93 has a x16 interface, while Avaota is wired x32.
- **Voltage:** the FRDM-IMX93 runs VDDQ at 0.6 V (LPDDR4X), while Avaota ties VDDQ to 1.1 V (LPDDR4). A part works on both only if its datasheet explicitly supports both modes. The FRDM's Micron part does support both, but it is x16 single channel, so Avaota could at best run it 16 bits wide. `libdram` has a 16-bit auto-detect path, but this is untested and not worth the rework.
- **Rework:** each move is a fine-pitch BGA rework job on both boards.

**What *is* the same** is the JEDEC LPDDR4 protocol: commands, mode registers (MR11 ODT, MR12/MR14 Vref, …) and the training ideas (write leveling, DQS gating, read/write eye, Vref). So compare **methods and results** across the two boards, for example eye width in ps and Vref window in mV, rather than the same physical chip.

### 2.12 JTAG on the FRDM-IMX93: what it adds for DDR training

**Getting debug access.** Sources: NXP's community post *How to use J-Link on FRDM-IMX93* (saved in [2.docs/jlink-imx93](2.docs/jlink-imx93)) and SEGGER's i.MX93 wiki page.

| | |
|---|---|
| Interface | **SWD**. VREF is **1.8 V**, taken from TP707. Remove **R3017 and R3018**. |
| Boot switch | SW1 = `1001`: serial download, M33 only. SW1 = `0011`: A55 boot. NXP's log shows the A55 reached at the U-Boot prompt. |
| DAP | DPIDR `0x5BA02477`, CoreSight SoC-400. AP0 = AHB-AP, **AP1 = APB-AP (A55)**, AP2 = MEM-AP, AP3 = AHB-AP (M33). |
| A55 debug | core 0 at **`0x80810000`**, CTI at `0x80820000`. Same base as the FRDM-IMX95's measured `0x80810000`. |
| SEGGER's caveats | The A55 needs a boot image that enables debug. There is no generic core reset. Disable caches before downloading code. |

**Where DDR training runs.**

- **i.MX93:** in U-Boot SPL **on the A55**. The call chain is `spl_dram_init()` → `ddr_init()` → `ddr_cfg_phy()`. `ddr_cfg_phy()` does the following:
  1. Loads the Synopsys PMU firmware into the PHY (IMEM `0x50000`, DMEM `0x54000`).
  2. Writes the message block.
  3. Starts the PMU (`0xd0099`).
  4. Polls the mailbox (`0xd0004/31/32/34`).
  5. Reads the results (CDD).
  6. Loads the PIE (the PHY Init Engine program).
  7. Saves the trained CSRs.

  For FRDM-IMX93 (mainline `board/nxp/imx93_frdm/lpddr4x_1gb_timing.c`):
  - 1D training runs at 3733, 1866 and 625 MT/s, plus 2D at 3733.
  - `SequenceCtrl = 0x131f`: DevInit, WrLvl, RxEn, RdDQS1D, WrDQ1D, RdDeskew, MxRdLat, LPCA (CA training).
  - `HdtCtrl = 0xC8`: stage-completion messages only.
- **i.MX95:** DDR init runs in the **OEI on the Cortex-M33**, before the A55 starts. The `frdm-imx95-pro-jtag` notes rate M33 debug as low-confidence because of the ELE. **So the i.MX93 is the easier NXP board for watching DDR init.**

**What JTAG adds on the i.MX93 (untested):**

1. **Edit the message block before the PMU starts.** Break in `ddr_cfg_phy()` just before the `0xd0099` writes, then poke DMEM and resume. For example:
   - Run one training step at a time through `SequenceCtrl`.
   - Raise the verbosity with `HdtCtrl` = `0x05` (eye delays) or `0x04` (eye contours). The PMU then streams them through the mailbox, which U-Boot's `decode_streaming_message()` reads as string indices and arguments.
   - Change the Vref and MR fields.

   No rebuild is needed.
2. **Dump the results.** That means the message block after training, and every PHY CSR in the board file's `ddr_ddrphy_trained_csr[]` list (the trained delays).
3. **Name everything with ST's open Synopsys PhyInit sources.** TF-A for STM32MP2 includes these, BSD-licensed:
   - `drivers/st/ddr/phy/phyinit/include/ddrphy_csr_all_cdefines.h` (~6,900 lines of CSR names),
   - `drivers/st/ddr/phy/firmware/include/mnpmusrammsgblock_lpddr4.h` (message-block fields with descriptions).

   NXP's PMU control writes match ST's names:
   - `0xd0000` = MicroContMuxSel
   - `0xd0004` = UctShadowRegs
   - `0xd0031` = DctWriteProt
   - `0xd0032` = UctWriteOnlyShadow
   - `0xd0034` = UctDatWriteOnlyShadow
   - `0xd0099` = MicroReset

   Layouts can differ between firmware versions, so check each field against the values U-Boot writes.
4. **What JTAG still can't do:** step the PMU firmware. It runs on a microcontroller inside the PHY, which is not on the DAP.

Points 1 and 2 also work without JTAG: edit the timing file and build SPL with `DEBUG`. JTAG removes the rebuild loop and still works when training hangs.

**CH347F on the FRDM-IMX93.** Feasible, with three changes from the FRDM-IMX95 setup:

- **Level:** set the module to **1.8 V I/O**, or use a level shifter. The FRDM-IMX95 and T113 setups ran at 3.3 V.
- **Protocol:** SWD only. OpenOCD's CH347 driver limits SWD to 5 MHz.
- **Config:** OpenOCD has no upstream `imx93.cfg`. Copy `frdm-imx95-pro-jtag/openocd/target/imx95.cfg` and change it as follows:
  - SWD ID `0x5ba02477`;
  - 2 A55s instead of 6, at `0x80810000` (core 1 probably at `+0x100000` like the i.MX95, unverified);
  - drop the M7;
  - M33 on AP3.

**Getting debug before DDR init:** NXP's post only shows the A55 at the U-Boot prompt, after DDR is up. To catch SPL before `ddr_init()`:
1. Boot SPL over `uuu` (SDP).
2. Add a spin loop on a volatile flag at the start of `spl_dram_init()`.
3. Attach, clear the flag, and continue.

### 2.13 FRDM-IMX93 as a DDR learning board: compatible parts, what it teaches, its limits

**Which board for what:**

| Board | Best for |
|---|---|
| **FRDM-IMX93** | **The industrial workflow:** NXP DDR tool, Synopsys PHY plus PMU firmware, message block, vTSA, and A55 JTAG during SPL |
| **Avaota-A1** | **Algorithm internals:** a software eye scan that runs on the CPU and can be reversed; open mainline driver; FEL |
| FRDM-IMX95 Pro | LPDDR5 at 6400 MT/s, x32, 16 GB. DDR init runs in the OEI on the M33, which is harder to watch. |

**i.MX93 DRAM limits** (NXP product page, i.MX 93 Memory Compatibility Guide, AN14012):

- **Interface:** x16 LPDDR4/LPDDR4X with inline ECC.
- **Speed:** up to **3733 MT/s** on the 11x11 package, 3200 MT/s on the 9x9 package. FRDM-IMX93 trains at 3733 / 1866 / 625 MT/s.
- **Size:** at most **16 Gb (2 GB)**, single rank, single channel, 17 row address bits.

**Compatible parts.** These are from NXP's i.MX 93 Memory Compatibility Guide, as seen in search snippets; the full page is behind Cloudflare. All are x16, 200-ball. NXP notes that the table is updated over time, has footnotes (4, 8, 10) not read here, and that some parts may not run at low speed or with DQ ODT active. Open the guide before buying.

| Density | Vendor | Part | Mode |
|---|---|---|---|
| 16 Gb / 2 GB | Micron | **MT53E1G16D1FW-046 AAT:A** (on the FRDM; DigiKey lists it obsolete) | LPDDR4 + LPDDR4X |
| 16 Gb / 2 GB | Micron | **MT53E1G16D1ZW-046 AAT:C** (DigiKey's suggested replacement) | LPDDR4/4X |
| 16 Gb / 2 GB | Kingston | D1611PM3BDGUI-U, C1612PC2WDGTKR-U | LPDDR4 |
| 8 Gb / 1 GB | Micron | MT53D512M16D1DS-046 AAT | LPDDR4/4X |
| 8 Gb / 1 GB | Nanya | NT6AN512M16AV-J1I (LPDDR4), NT6AP512M16BV-J1I (LPDDR4X) | see Part column |
| 4 Gb / 512 MB | Nanya | NT6AP256M16AV | LPDDR4X |
| 4 Gb / 512 MB | ISSI | IS43LQ16256B-062BLI | LPDDR4 |
| 2 Gb / 256 MB | ISSI | IS43LQ16128A-062BSLI | LPDDR4 |

Micron's own chart lists 8 Gb and 16 Gb MT53, x16, 200-ball TFBGA parts for i.MX 93x.

**Two extra constraints on the FRDM board itself:**

- **Voltage.** The board runs LPDDR4X (VDDQ 0.6 V), so a drop-in replacement must support LPDDR4X mode. LPDDR4-only parts (the Kingston, the ISSI, Nanya NT6AN…) also need the DRAM VDDQ and the SoC's DRAM I/O rail moved to 1.1 V. That is a PMIC/board change, not a chip swap.
- **Size and timings.** U-Boot already ships FRDM timings for 1 GB and 2 GB (`lpddr4x_1gb_timing.c`, `lpddr4x_1cs_2gb_timing.c`, `lpddr4x_2cs_2gb_timing.c`). For any other part, generate a new timing file with the NXP DDR tool.

**What it teaches that industry uses:**

- **The NXP flow, as done on every custom i.MX board:**
  1. DDR tool configuration.
  2. `lpddr4x_timing.c` in U-Boot.
  3. Training.
  4. Overnight stress test.
  5. vTSA margins.
  6. ODT, drive and Vref tuning.
  7. Temperature validation.

  It's the same tool across i.MX 8M, 91, 93 and 95.
- **The Synopsys PHY plus training-firmware model** (message block, `SequenceCtrl`, `HdtCtrl`, CDD, trained CSRs). NXP, ST (STM32MP2) and others use it, so it transfers.
- **Real margins at a real speed.** At 3733 MT/s, one UI is about 268 ps. That is tighter than Avaota's 2400 MT/s (417 ps).
- **Industrial features:**
  - inline ECC, to try on this board;
  - three frequency set points (DRAM DVFS);
  - self-refresh and retention.

**What it can't teach:**

- **Width and topology:** x16 only, 1 channel, 1 rank. No x32/x64 lane-to-lane effects, no multi-rank or dual-channel behaviour. The i.MX95 is x32.
- **Newer DRAM types:** no LPDDR5 (WCK clocking; the FRDM-IMX95 Pro has it at 6400 MT/s), no DDR4/DDR5 fly-by and DIMMs.
- **Writing a training algorithm:** the PMU firmware is closed. You learn to drive and judge it, which is what the industrial job is. Writing one is the chip-company job; for that, use the Avaota soft training.
- **Bad boards:** the FRDM is a reference layout that passes. To see margin loss, induce it: lower Vref, change ODT or drive strength, raise the frequency, or heat and cool the board.

**Is the i.MX93 limited by RAM size and speed?** Yes: 2 GB maximum and 3733 MT/s. For learning DDR training, though, the size is irrelevant, and 3733 MT/s is already fast. The real limits are **x16 single-channel and no LPDDR5**. Those are covered by your FRDM-IMX95 Pro when you need them.

**A link back to Avaota:** `libdram` contains `ddrphy_phyinit_C_initPhyConfig`. That is exactly the name of Synopsys PhyInit step C, the same step as ST's `ddrphy_phyinit_c_initphyconfig.c`, so Allwinner's code borrows at least the PhyInit naming and structure. Compare that function in Ghidra against ST's open source. Don't assume the T527 PHY *is* Synopsys, though: the mainline H616 driver calls its PHY "completely unknown" and different from the H6's.

### 2.14 The sequence, step by step: which parts are blobs

![DDR init and training: what is open, what is a blob](ddr-init-blob-map.svg)

[`ddr-init-blob-map.svg`](ddr-init-blob-map.svg) has four columns: the Avaota vendor path, the Avaota mainline path, the FRDM-IMX93 and the FRDM-IMX95 Pro. A yellow band steps through the rows when the SVG is opened in a browser.

| Step | Avaota-A1 · vendor (`libdram`) | Avaota-A1 · mainline U-Boot | FRDM-IMX93 | FRDM-IMX95 Pro |
|---|---|---|---|---|
| 1. Load the init code | ROM → boot0 / SyterKit (or FEL) | ROM → SPL (or FEL) | ROM + **ELE** (signed) → SPL (or SDP) | ROM + **ELE** → OEI on the **M33** (or SDP) |
| 2. Clocks, voltage | blob on the A55 | open | open | open (imx-oei) |
| 3. Controller setup | blob on the A55 | open | open code + tool-made values | same |
| 4. PHY setup, ZQ | blob on the A55 (`ddrphy_phyinit_C_initPhyConfig`…) | open, magic offsets | open code + tool-made CSR values | same, newer PHY CSR map |
| 5. Load training firmware | — | — | **blob** → PHY IMEM/DMEM, plus the message block (data) | **blob**, four binaries: IMEM 64,372 B + DMEM 65,536 B, plus the QuickBoot pair (25,756 B and 65,536 B), loaded by eDMA (§2.20) |
| 6. Training | blob code starts the **PHY hardware engines** | open code starts the same engines (TPR10 bits) | **blob inside the PHY's MCU** (WrLvl, RxEn, Rd/WrDQ, deskew, CA, 2D); SPL only polls and reads results | **blob inside the PHY's MCU**, LPDDR5 6400 MT/s; **measured 4.87 s** for full training on the board (QuickBoot not measured) |
| 7. Per-bit delays, eye scan | blob on the A55: **software eye scan** (`dst_dq_eye_scan`) | open, fixed delays, no eye scan | PIE program (opaque data); eye centering already done in the PMU | PIE per PState (opaque data) |
| 8. Size, hand off | blob on the A55 (auto-scan, write-back) | open (auto-detect) | open (timing table, CSR save) | open (5,698 trained CSRs, measured in the retention copy at M33 `0x2001A000`; QuickBoot data to NVM) |

**How to read it.**

- On the Avaota, every blob runs on the **CPU**, so you can step and reverse it. The only true black boxes are the PHY's hardware engines.
- On the i.MX93, everything around training is open. The training itself is a blob running **inside the PHY**, out of reach of JTAG. You control its inputs (the message block) and read its outputs (results, mailbox stream, trained CSRs).
- On the FRDM-IMX95-PRO, the code around training is open and runs on the M33 (imx-oei, BSD-3). Only the PHY's own MCU runs the closed firmware. The measurements are in §2.20.

### 2.15 Closed training firmware is the norm; recovery on the FRDM-IMX93

**Nobody publishes PHY training firmware.**

- **Why it stays closed:** it is licensed IP (Synopsys, Cadence, …), it encodes the PHY's analog characterisation, and its quality is a selling point. The SoC vendor gets a binary and may not publish its source. NXP ships the Synopsys PMU images as binaries in `firmware-imx`, under its EULA.
- **What *is* public:**
  - the DRAM side (JEDEC),
  - the controller (in the RM),
  - the PHY's register names and init flow (ST published Synopsys PhyInit in TF-A).
- **Counter-examples exist, much like the reverse-engineered GPU drivers:**
  - Allwinner (mainline U-Boot, reverse-engineered),
  - coreboot's native RAM init for older Intel chipsets,
  - LiteDRAM on FPGAs.
- **Checked locally on the FRDM-IMX95-PRO (§2.20):** the imx-oei repo at `e9bce6f4` (BSD-3) has the host code that loads the firmware and runs the sequence. It has no firmware in it. The four firmware binaries are in the Yocto deploy directory, as raw data with no source next to them.

**So the numbers are the industrial skill.** A board engineer rarely writes training code. They:

- choose the configuration (timings, MRs, ODT, drive strength, Vref, frequency set points);
- run training and read its results (trained delays, Vref, CDD);
- prove the margins with stress tests, vTSA and temperature;
- tell a layout problem apart from a configuration problem or a bad part.

Exercises on the FRDM-IMX93:

- Diff the 1 GB and 2 GB timing files.
- Regenerate the timing file for MT53E1G16D1ZW with the DDR tool, and diff it against the current one.
- Change ODT or drive strength and watch the vTSA eye change.
- Compare the per-lane trained delays with the trace lengths in the FRDM layout.

**Recovery when DDR init fails: the FRDM-IMX93 can't be bricked either.**

- **SPL runs from on-chip RAM (OCRAM).** `flash.bin` contains the ELE container, SPL and the DDR training firmware. The ROM loads it into OCRAM, and SPL loads the training firmware from there into the PHY. DRAM is needed only *after* `ddr_init()`, for ATF and U-Boot proper.
- **The backup is the ROM's serial downloader.**
  1. Set SW1[3:0] = `0001`.
  2. Connect USB-C to P2, the console to P16, and power to P1.
  3. Run `uuu` to load a fixed `flash.bin` straight into OCRAM. The eMMC is not touched.

  This is how the NXP DDR tool runs its test image too. Other options: SD boot (`0011`), or reflash the eMMC with `uuu -b emmc_all`. The default `0010` is eMMC.
- **Falcon mode doesn't help here.** It only makes SPL boot Linux directly, skipping U-Boot proper, which is about boot time. It still needs working DRAM.

| | Avaota-A1: FEL | FRDM-IMX93: serial downloader (SDP) |
|---|---|---|
| Lives in | Boot ROM; needs no DRAM | Boot ROM; needs no DRAM |
| Entry | FEL button | SW1 = `0001` |
| Accepts | Any read, write or execute command (`xfel`) | A boot image (`flash.bin`) via `uuu` |
| Peek/poke without a debugger | Yes | No: use SWD/JTAG |
| DDR iteration loop | `xfel` a DRAM-init payload, read the registers back | Edit `lpddr4x_timing.c` → rebuild `flash.bin` → `uuu -b spl flash.bin`, or use the NXP DDR tool |

### 2.16 The three boards side by side

Checked against:

- this repo's schematic and BOM;
- U-Boot master: `drivers/ddr/imx`, `board/nxp/imx93_frdm`, `arch/arm/dts/imx9{3,5}-u-boot.dtsi`;
- `nxp-imx/imx-oei` master: `oei/ddr/*`, `boards/mx95lp5*`, `boards/mx95lp4x*`;
- the i.MX95 RM chapter 114 in `~/praxis/imx/rm`;
- the `frdm-imx95-pro-jtag` notes.

**Silicon and DRAM**

| | Avaota-A1 | FRDM-IMX93 | FRDM-IMX95 Pro |
|---|---|---|---|
| SoC | Allwinner T527: 8× A55, E906 RISC-V, HiFi4 | i.MX93: 2× A55 1.7 GHz, M33, Ethos-U65 | i.MX95 (9596): 6× A55, M7, M33, Neutron NPU |
| DRAM on the board | 1× LPDDR4, x32, 4 GB | 1× Micron MT53E1G16D1FW (LPDDR4/4X), x16, 2 GB, run as LPDDR4X | LPDDR5, x32, 16 GB |
| SoC limits | 4 GB; 1200 MHz clock (≈ 2400 MT/s) | 2 GB; 3733 MT/s (11x11), 3200 (9x9) | x32; LPDDR5 6400 / LPDDR4X 4266 MT/s (19x19) |
| Inline ECC | not in the UM feature list | yes | yes |

**DDR IP**

| | Avaota-A1 | FRDM-IMX93 | FRDM-IMX95 Pro |
|---|---|---|---|
| Controller | uMCTL2-style; undocumented here, documented elsewhere (2.10) | NXP DDRC (`CS0_BNDS`, `TIMING_CFG_0`, `DDR_SDRAM_CFG`, …) | the **same NXP DDRC family**, RM ch. 114 (122 registers) |
| PHY | Allwinner's own (H616 family); undocumented | Synopsys, older generation: IMEM 32 KB @ `0x50000`, DMEM 16 KB @ `0x54000` | Synopsys, newer generation: IMEM 64 KB @ `0x50000`, DMEM 64 KB @ `0x58000`, PState SRAM @ `0xA0000` |
| PHY config CSRs in the timing file | n/a | 129 | 84 (LPDDR4X EVK) / 87 (LPDDR5 EVK) |
| Trained CSRs saved | n/a | 976 | 3,357 (LPDDR4X) / 5,698 (LPDDR5) |

**Training**

| | Avaota-A1 | FRDM-IMX93 | FRDM-IMX95 Pro |
|---|---|---|---|
| Who trains | PHY hardware engines, plus a software eye scan on the CPU | PMU firmware **v2022.01**: separate **1D and 2D** images (`lpddr4_{i,d}mem_{1d,2d}_v202201.bin`) | PMU firmware **v2024.09**: **one** image (`lpddr5_{i,d}mem_v202409.bin`) plus QuickBoot images (`*_qb_*`) |
| Which CPU runs the host code | A55 (boot0 / SPL) | A55 (U-Boot SPL, OCRAM `0x2049A000`) | **M33** (OEI, TCM `0x1ffc0000`), before the A55 starts |
| Steps / `SequenceCtrl` | TPR10 bits; `tpr13` soft training | `0x131f` @ 3733, `0x121f` @ 1866/625, 2D `0x61`; `HdtCtrl 0xC8` | `0x17df` (LPDDR5, one PState @ 6400); `0x121f` on the LPDDR4X EVK; `HdtCtrl 0xC8` |
| Training time | ~0.26 s hardware + ~3.5 s soft scan (Allwinner guide's example log) | not measured: use SPL timestamps | ~4.9 s full; ~1 ms with QuickBoot (NXP community report) |
| Skip retraining | `libdram` writes trained parameters back to flash | no QuickBoot in U-Boot for i.MX93 | QuickBoot: OEI reuses saved results; U-Boot patches save them to NVM |

**Software, documents, tools**

| | Avaota-A1 | FRDM-IMX93 | FRDM-IMX95 Pro |
|---|---|---|---|
| Open host code | mainline U-Boot `dram_sun55i_a523.c` (GPL) | U-Boot `drivers/ddr/imx` (GPL) | `imx-oei` (BSD-3) |
| Closed parts | `libdram` (unstripped, 66 named functions) | Synopsys PMU firmware (firmware-imx 8.21), ELE | Synopsys PMU firmware (firmware-imx 8.28), ELE |
| Public DDR documents | DRAMC: a one-page feature list; Allwinner eye-adaptive guide | RM DDRC; HDG with SI targets; memory compatibility guide; ST's PhyInit headers (same PHY generation: DMEM `0x54000`) | RM ch. 114; `msb_ddr5.h` / `msb_ddr4x.h` in imx-oei; QuickBoot docs (AN14094, U-Boot) |
| Vendor tool | DragonHD (Windows, inside APST) | NXP DDR tool: configuration, stress, ODT/Vref sweep, vTSA | NXP DDR tool lists i.MX95; vTSA is listed for LPDDR4 only |

**Debug, recovery, price**

| | Avaota-A1 | FRDM-IMX93 | FRDM-IMX95 Pro |
|---|---|---|---|
| USB recovery | FEL button: read, write and execute anything | SDP: SW1 = `0001` + `uuu` | SDP: SW4 + `uuu` |
| Debug port | JTAG through the microSD socket (PF), 3.3 V, or PB on the LCD FPC; untested | SWD at 1.8 V after removing R3017/R3018; A55 at `0x80810000` (NXP's J-Link log) | JTAG test points, 3.3 V, 0 Ω links fitted; A55 at `0x80810000` measured; ETM → ETR trace working |
| Can you step the training? | **Yes**: all of it is CPU code | host side yes (SPL on the A55); PMU no | host side only if M33 debug opens (low confidence); PMU no |
| Price | $54.95 | ~$71–74 | ~$300 |

**What each board is best for**

| | Avaota-A1 | FRDM-IMX93 | FRDM-IMX95 Pro |
|---|---|---|---|
| Best for | Algorithm internals; reverse engineering; open code | The industrial NXP flow at LPDDR4; the easiest NXP board to watch | LPDDR5, x32, QuickBoot; the newest PHY and firmware |

### 2.17 You reversed the i.MX95 PHY firmware. Does it carry over to the i.MX93?

**Partly. Not as a drop-in.** The two chips use the same Synopsys PMU model and the same host protocol, but a different PHY generation and firmware generation. The evidence, side by side from open host code:

| Aspect | i.MX95 (imx-oei, FW 2024.09) | i.MX93 (U-Boot, FW 2022.01) | Carries over? |
|---|---|---|---|
| PMU control | `0xd0000` MicroContMuxSel; `0xd0099` = 9 → 1 → 0 to start, 1 to halt | identical | ✅ |
| Mailbox | `0xd0004` / `0xd0031` / `0xd0032` / `0xd0034`; codes `0x07` done, `0xff` fail, `0x08` streaming message | identical | ✅ your mailbox and streaming decoder |
| Controller | NXP DDRC (RM ch. 114) | same register family | ✅ |
| IMEM | `0x50000`, 64 KB | `0x50000`, 32 KB | ⚠ same base, half the size |
| DMEM / message block | `0x58000`, 64 KB → `SequenceCtrl` at CSR `0x58008` (addresses not re-checked on 2026-10-28) | `0x54000`, 16 KB → `SequenceCtrl` at CSR `0x54008` | ❌ different base address |
| Images | four separate binaries in the deploy directory: IMEM and DMEM, plus the QuickBoot pair (§2.20) | raw IMEM/DMEM; **1D and 2D are separate programs** | ❌ the 2D firmware is new work |
| LPDDR4 message-block layout | `msb_ddr4x.h`: `SequenceCtrl 0x10`, `Quickboot 0x19`, `MR12_A0 0x37`, `MR14_A0 0x39`, `TrainedVREFDQ_A0 0x4d` | ST's LPDDR4 block (same generation as the i.MX93): `SequenceCtrl 0x10`, `HdtCtrl 0x12`, `MR12_A0 0x37`, `MR14_A0 0x39`; `0x4b–0x4e` reserved | ✅ mostly the same byte offsets; the newer firmware fills slots that were reserved |
| LPDDR5 specifics | `msb_ddr5.h`: MR12 at `0x6e`, MR24/MR30, `TrainedDRAMDFE`/`DCA`; `SequenceCtrl 0x17df` | n/a | ❌ protocol-specific (WCK, DFE, DCA) |
| PHY config CSRs | 84 (LPDDR4X) / 87 (LPDDR5); the same 84 in both | 129 | ❌ **only 2 addresses in common** |
| Trained CSRs | 3,357 (LPDDR4X) / 5,698 (LPDDR5); 2,907 shared | 976, of which **436** also appear on the i.MX95 LPDDR4X | ⚠ about half |
| Byte lanes | 4 DBYTE blocks (`0x10xxx`–`0x13xxx`), x32 | 2 DBYTE blocks (`0x10xxx`–`0x11xxx`), x16 | ⚠ fewer lanes, same idea |
| Host CPU | M33 (OEI) | A55 (SPL) | the i.MX93 is *easier* to debug |

**What transfers:**

- the host protocol and your mailbox/streaming decoder;
- the PMU instruction set, *if* both generations use the same core (see the first check below);
- the LPDDR4 message-block conventions;
- the controller knowledge;
- your method and tools (Ghidra loader, CSR naming).

**What you redo:**

- the function map of a 2022.01 build (older, and split into 1D and 2D);
- the PHY CSR names (use ST's PhyInit headers, which match the i.MX93's generation);
- everything LPDDR5-specific, which has no i.MX93 equivalent.

**So: the same *kind* of result, yes, for the LPDDR4 training steps.** Expect it to be much faster than the first time, but not free.

**How to check it on the other PC.** The firmware files come from firmware-imx: 8.21 for the i.MX93. For the i.MX95, the older yocto-imx95 tree has recipes for 8.28 and 8.30, and the PRO tree has 8.31 and 8.32. Which recipe ships the `v202409` binaries was not traced, so pin the version when you copy them. The licence terms (NXP's EULA) were not re-read on 2026-10-28.

1. **Is the instruction set the same?** Load `lpddr4_imem_1d_v202201.bin` with your i.MX95 Ghidra module or disassembler. Clean decoding with sane control flow means the same core; garbage means a new ISA. This is the deciding check, and I couldn't verify it from public sources.
2. **Use the bridge firmware.** firmware-imx 8.28 also ships `lpddr4x_{i,d}mem_v202409.bin` for the i.MX95 LPDDR4X EVK. It has the same PHY and firmware generation as your LPDDR5 work, but the LPDDR4X protocol like the i.MX93.
   1. Diff it against your LPDDR5 database with BinDiff or Diaphora. That separates the shared core from the protocol code.
   2. Diff it against i.MX93 v202201. That separates the generation changes.
3. **Rebase the message block.** Every DMEM reference moves from `0x58xxx` to `0x54xxx`. The field offsets inside the block mostly stay the same.
4. **Validate live on the FRDM-IMX93.**
   - Set `HdtCtrl` (CSR `0x54009`) to `0x05` or `0x04`, and check the streaming-message string indices against your decoded table.
   - Break in SPL before `0xd0099` (section 2.12) and flip `SequenceCtrl` bits to confirm which code paths run.
   - Dump the 976 trained CSRs and compare them with what your model predicts.

### 2.18 What the five boards teach together

You own T113-S3, RZ/V2L SMARC, Avaota-A1, FRDM-IMX93 and FRDM-IMX95 Pro. Together they cover every mainstream embedded DRAM generation from DDR3 to LPDDR5, three ways of training, and three vendors.

**What each board has:**

| | T113-S3 | RZ/V2L SMARC | Avaota-A1 | FRDM-IMX93 | FRDM-IMX95 Pro |
|---|---|---|---|---|---|
| DRAM | **DDR3**, in the package, x16, 128 MB | **DDR4**, 1 chip, x16, 2 GB | **LPDDR4**, x32 (2 channels), 4 GB | **LPDDR4X**, x16, 2 GB | **LPDDR5**, x32, 16 GB |
| Speed | 792 MHz = 1584 MT/s | DDR4-1600 | ≈ 2400 MT/s | 3733 MT/s | 6400 MT/s |
| One UI (bit time) | ≈ 631 ps | ≈ 625 ps | ≈ 417 ps | ≈ 268 ps | ≈ 156 ps |
| Training | PHY engines + CPU code (`dqs_gate_detect`, `eye_delay_compensation`) | PHY commands + **algorithms in C** (write leveling, **software Vref sweep**, bit leveling, `opt_delay`, SL) | PHY engines + **software eye scan** (blob on the CPU) | **PMU firmware** v2022.01 (1D + 2D) | **PMU firmware** v2024.09 + QuickBoot |
| DRAM init code | open: U-Boot `dram_sun20i_d1.c`, based on decompiled Allwinner code (via awboot) | open: Renesas TF-A BL2 `plat/renesas/rz/common/drivers/ddr/ddr.c` (BSD-3), plus generated parameter tables | open mainline / closed `libdram` | open U-Boot + closed PMU firmware | open imx-oei + closed PMU firmware |
| Register names | none (magic offsets) | numbered only (`DDRMC_R000…`, `DDRPHY_R00…`) | none (magic offsets) | controller in the RM; PHY names via ST's PhyInit | controller in the RM ch. 114 |
| Inline ECC | no | yes (the BSP skips it: "ECC is unused") | not listed | yes | yes |
| Recovery | FEL | SCIF download + Flash Writer over UART | FEL | SDP + `uuu` | SDP + `uuu` |
| Debug | JTAG via SD sniffer (yours, working) | JTAG/SWD; OpenOCD has `renesas_rz.cfg` (RZ/V2L: 2× A55 + M33) | JTAG via SD (untested) | SWD at 1.8 V (rework) | JTAG + ETM trace (yours, working) |

**Coverage:**

- **DRAM types:** DDR3 → DDR4 → LPDDR4 → LPDDR4X → LPDDR5.
- **Training styles:**
  1. Open C on the CPU: T113, RZ/V2L, Avaota mainline.
  2. A closed blob on the CPU: Avaota `libdram`.
  3. Firmware inside the PHY: i.MX93, i.MX95.
- **Vendors:** Allwinner, Renesas, NXP (with Synopsys IP).

**Not covered:** DDR5, LPDDR5X, DIMMs and fly-by multi-rank boards, x64 server memory, and measuring signal integrity with a scope.

**What each board teaches best:**

| Board | Lesson |
|---|---|
| **T113-S3** | **DDR3 fundamentals in plain C.** All of the init is readable, and you already step it with JTAG. The RAM sits inside the SoC package, so there is no PCB routing: training sees only the package. |
| **RZ/V2L SMARC** | **DDR4, and a vendor's own training algorithms in readable C.** `exec_trainingVREF()` sweeps Vref, measures two window edges per lane and picks the middle. That is a real eye/Vref search, the white-box version of what the PMUs hide. It also has DDR4-specific ideas (bank groups, RTT_NOM/WR/PARK, VrefDQ in MR6) and inline ECC you can turn on. |
| **Avaota-A1** | **LPDDR4 with two channels, plus reverse engineering.** **The T113 driver is your Rosetta stone:** it comes from the same Allwinner code lineage, and 10 function names match `libdram` exactly (`init_DRAM`, `mctl_sys_init`, `mctl_com_init`, `mctl_channel_init`, `mctl_core_init`, `DRAMC_get_dram_size`, `dramc_simple_wr_test`, `auto_scan_dram_size`, `auto_scan_dram_rank_width`, `auto_scan_dram_config`). The open layout and IBIS models let you connect results to the PCB. |
| **FRDM-IMX93** | **The industrial workflow:** NXP DDR tool, vTSA eyes, message block, `HdtCtrl` streaming, and JTAG on SPL. |
| **FRDM-IMX95 Pro** | **LPDDR5 and boot time.** Training takes about 5 s; QuickBoot cuts it to about 1 ms, which matters directly for your fast-boot work. Also your PMU reverse engineering, and porting it to the i.MX93 (2.17). |

**Suggested order:**

1. **Fundamentals, open code (T113, then RZ/V2L).**
   - Read `dram_sun20i_d1.c` next to JESD79-3 (DDR3), and Renesas `ddr.c` next to JESD79-4 (DDR4).
   - Decode the mode registers. For example, T113 MR0 = `0x1c70`: burst length, CAS latency, write recovery.
   - Add a `printf` in `exec_trainingVREF()` for `window_0`, `window_1` and `current_vref`. That is your first Vref-versus-window plot.
2. **LPDDR4 and reverse engineering (Avaota).**
   - Experiment with the mainline TPR10 bits (2.4).
   - Reverse `dst_dq_eye_scan` (2.9), using the T113 driver and the RZ/V2L Vref sweep as references for what such code looks like.
3. **The industrial PMU flow (FRDM-IMX93).** DDR tool, stress, vTSA, message-block experiments (2.12, 2.15).
4. **LPDDR5 and QuickBoot (FRDM-IMX95).** Measure full training against QuickBoot, then carry your PMU work to the i.MX93 (2.17).

**The same experiments on all five boards:**

1. **Margin shmoo.** Sweep frequency against Vref, convert the eye width to ps using each board's UI, and compare across technologies.
2. **Training time and skip mechanisms.** Allwinner writes parameters back to flash; QuickBoot reuses saved results; the RZ/V2L and i.MX93 retrain on every boot.
3. **Fault injection.** Use wrong ODT, drive strength or Vref, then compare the failure signatures: a training failure, memtest errors, or silent corruption.
4. **ECC.** Turn on inline ECC on the RZ/V2L, i.MX93 and i.MX95. The i.MX95 RM lists error-injection registers (`DATA_ERR_INJECT_HI/LO`, `ERR_INJECT`) for forcing single-bit and double-bit errors.
5. **Self-refresh, retention, frequency set points, temperature.** Use a hair dryer or freezer spray while a memtest runs.

### 2.19 Does it pay off for an embedded Linux BSP target?

**Only a thin slice of it does. The full DDR programme is a specialist path, not a BSP path.**

Your own survey (`elb1-t113/4.docs/reports/Embedded Linux industry requirements.md`, about 20 postings, 2025–2026) found:

- **"DDR initialisation or training almost never appears as a hiring requirement."** It is a rare skill, not an expected one.
- **What BSP employers rank, in order:**
  1. bring-up and low-level debug (JTAG, boot chain, DT, drivers);
  2. kernel lifecycle (uprevs, SBOM/CVE, CRA);
  3. signed A/B OTA;
  4. verified boot;
  5. boot time;
  6. … ;
  11. upstream record, which is strong at consultancies.
- Neither Bootlin's nor the Linux Foundation's courses teach DDR or JTAG-level bring-up. So a *documented* JTAG-plus-DDR bring-up stands out, but only as **evidence of bring-up**, not as DDR science.

The full-time DDR jobs (2.7) are at chip companies (AMD, Intel, Qualcomm, Cadence). They want an EE background and post-silicon lab years, mostly in the US or Asia.

**You already have the best BSP-shaped DDR result:** DDR QuickBoot on the FRDM-IMX95 Pro took **3.118 s → 0.234 s (−2884 ms)**, the biggest single win in `meta-fastboot-imx95`. That is how DDR knowledge earns its place on a BSP CV: as a boot-time, bring-up or reliability number.

**Keep these.** About 4–6 weeks in total, all of it reading as BSP work:

| Deliverable | Board | Time | BSP signal it proves |
|---|---|---|---|
| **DDR bring-up as if for a custom board:** DDR tool config → `lpddr4x_timing.c` in SPL → `uuu` recovery loop → overnight stress + vTSA → a one-page validation report | FRDM-IMX93 | 1–2 weeks | #1 bring-up ("first power-on to a stable platform", EVT/DVT) |
| **DDR's share of boot time:** SPL timestamps of DDR init on i.MX93, Avaota, T113, RZ/V2L, next to your i.MX95 QuickBoot result | all | 2–3 days | #5 boot time, measured on four SoCs |
| **Early-boot debug write-up:** halt SPL/BL2 inside DDR init over JTAG/SWD; hardware-first triage | i.MX93 (SWD), T113, RZ/V2L | ~1 week | #1 register-level debug |
| **ECC and crash records:** enable inline ECC, inject errors through the DDRC, check how Linux reports them (EDAC, if a driver exists; a missing one is an upstream opportunity), ramoops in an ECC region | i.MX95 or RZ/V2L | ~1 week | #7 reliability, plus possibly #11 upstream |

**Defer unless you choose the memory-firmware career:**

- reversing `libdram` (2.9);
- porting your i.MX95 PMU reverse engineering to the i.MX93 (2.17);
- RAM chip swaps (2.8);
- the five-board shmoo matrix.

If you want one depth piece, time-box it to 2–3 weeks: the RZ/V2L Vref training (open C, easiest), or `dst_dq_eye_scan`.

**The Avaota-A1 is still worth buying, mainly for BSP reasons.** A523/T527 is still being upstreamed (the DRAM init only reached U-Boot in July 2025), so it is a live target for mainline patches. FEL makes it safe to experiment on, and its DDR stays a side lesson.

### 2.20 i.MX95 DRAM on the FRDM-IMX95-PRO: what we found locally

Checked on the board and in the local source trees on 2026-10-20, and re-checked on 2026-10-28. The board is the PRO: six A55, M7, M33 and 16 GB LPDDR5. The §2.6 row that gave the FRDM-IMX95 as 8 GB LPDDR4X was wrong, and it is corrected there.

**Status.** The notes, logs and disassembly are untracked files in the imx95 repo and are not committed. The submodule in this repo (`2.docs/frdm-imx95-pro-jtag`) is pinned at the pushed commit `453feac`, which does not include them. The sources are listed in §4.

**Correction: the i.MX95 DDR training is not fully open.** It has three parts, in three states:

| Part | State | Evidence |
|---|---|---|
| Controller and PHY setup, timing tables, firmware loading, message block, sequencing, saving the trained values | **Open**: NXP imx-oei, BSD-3 | `LICENSE.txt` and `oei/ddr/` at `e9bce6f4`; the firmware is loaded through the eDMA hook in `ddr.h` |
| Training algorithm (write leveling, read and write training, eye search) | **Closed binary** | `lpddr5_{imem,dmem}[_qb]_v202409.bin` in the Yocto deploy directory: raw data, no ELF, no source on disk. The OEI repo contains no firmware. |
| What the binary does | **Our reverse engineering** | `ddr-phy-fw-arcv2.asm`: 22,238 lines of ARCv2 disassembly. A disassembly, not source. |

The firmware sizes are: IMEM 64,372 bytes and DMEM 65,536 bytes for the full image, and 25,756 bytes and 65,536 bytes for the QuickBoot pair. The PRO machine config names all four in `DDR_FIRMWARE_NAME`.

**Measured on the board (2026-10-20):**
- **Memory:** LPDDR5-6400, x32, no ECC, 16 GB (`0x080000000`–`0x47FFFFFFF`, from the SM monitor's `ddr` command). UM12527 names the part Micron MT62F4G32D8DV-023FAIT. The quick start guide says 16 GB LPDDR5, 32-bit.
- **Boot path:** the SDP/uuu boot runs full 1D training on every boot; QuickBoot is not used on that path. The OEI reports `TRAINING complete in 4871966 us` (4.87 s), `IMEM + DMEM load in 3317 us`, and `done, err = 0`. U-Boot then sees 15.8 GiB.
- **Build:** the OEI is `Build 217, Commit e9bce6f4`, for SoC MIMX95 B0 on board mx95lp5. That is the revision pinned in the mirror, so the binary and the source are the same version.
- **Console:** the OEI prints to the SM console (ttyACM3), the same port as the SM monitor.
- **Trained values:** the OEI keeps a retention copy in M33 TCM (`struct ddr_info` at `0x2001A000`). It holds 5,698 trained PHY CSR entries, the same count as the save list in the config. Six examples, config placeholder → trained value: `0x200a5` 0 → 0x01, `0xd0036` 0 → 0x00, `0x200bd` 0 → 0xff, `0x20300` 0 → 0x0808, `0x20303` 0 → 0x09, `0x20302` 0 → 0x26.
- **Speed:** 6400 MT/s is the top LPDDR5 setpoint in this package. The part's 7500 and 8533 MT/s ratings are not used, because the config has no higher setpoint.

**Reading DDR: JTAG and the SM monitor.**
- JTAG cannot read DDR from the A55 side. The DDRC at `0x4E080000` faults on both the AHB-AP and the APB-AP, and the PHY at `0x4E800000` reads zero. The DDR sits in the M33/SM secure domain (TRDC). OCRAM reads fine, so the JTAG rig itself works.
- The SM monitor can read the DDRC (`md 0x4e080000`). The PHY still reads zero from the M33, because its APB mux is off after training.

**Still open:**
- The training algorithm. Reverse engineering can document it, but it cannot replace it with source.
- Most PHY CSR meanings. The OEI names the message block, not each PHY register.
- Margins: the NXP DDR Tool's vTSA eye and an overnight stress run on this board have not been done.
- QuickBoot: the ~1 ms figure in §2.14 comes from the notes and is not measured.
- Whether the DDR Tool (Config Tools) runs on Linux for the validation part.
- Whether the EVK's 19×19 board carries the same Micron part. Not checked.

---

## 3. Avaota-A1 vs T113-S3: what the Avaota adds

**Sources.**

- **T113 side:** your `elb1-t113` README and its field docs (tags `[V]` there), plus the industry report.
- **Avaota side:**
  - the T527 datasheet V0.95 and user manual V0.94 in `2.docs`;
  - schematic and BOM v1.7;
  - mainline Linux `arch/arm64/boot/dts/allwinner/sun55i-a523.dtsi` and `sun55i-t527-avaota-a1.dts` (torvalds master, read 2026-10-28);
  - U-Boot master;
  - upstream TF-A.

`[?]` = not verified on hardware.

### 3.1 Silicon

| | T113-S3 (elb1, MQ-Dual, LCPI-PC) | T527 (Avaota-A1) | What it adds |
|---|---|---|---|
| CPU | 2× Cortex-A7, ARMv7-A, 32-bit | **8× Cortex-A55, ARMv8.2-A**, AArch64 + AArch32 at every EL; DynamIQ big.LITTLE (L2 64 KB little / 128 KB big, DSU with L3); up to 1.8 GHz | 64-bit, EL0–EL3, two clusters, 8-core SMP |
| Interrupts | GIC-400 (GICv2) | **GIC-600 (GICv3)** | redistributors, affinity routing, system-register CPU interface |
| Extensions | — | TrustZone, **RAS**, optional crypto extensions | EL3 firmware, RAS error records |
| Debug/trace | ARMv7.1 debug; **no ETM** (your doc 80) | **CoreSight SoC-600**; UM: "each core allows tracing supported by ETM"; CoreSight timestamp generator at `0x08010000` / `0x08020000` | instruction trace *if* a sink exists (3.4) |
| DRAM | **128 MB DDR3 in the package** (S4: 256 MB) | **4 GB LPDDR4 x32**, external chip | real memory; DRAM init and training (section 2) |
| GPU | none (software rendering, G2D) | **Mali-G57 MC1** | a real 3D/compute stack (Panfrost/Mesa) |
| NPU | none | **2 TOPS** (Vivante GC per the mainline node) | ML acceleration |
| Video engine | 1080p H.264/H.265 decode (Cedrus; you measured 111 fps) | **4K60 H.265/VP9 decode, 4K30 H.264 decode, 4K25 H.264 encode** | 4K, plus an encoder |
| Display out | RGB, LVDS, 2-lane DSI (your REV5), TV out; one LCD controller | **HDMI 2.0, eDP 1.3, 4+4-lane DSI, 2× dual-link LVDS, 2× RGB** | multi-display, HDMI/DP |
| Camera in | parallel DVP (CSIC; your own driver) | **MIPI CSI 4+4 lanes, ISP**, parallel CSI | MIPI CSI-2 + an ISP (your i.MX95 camera roadmap, on cheap hardware) |
| High-speed I/O | USB 2.0 only | **USB 3.1 / PCIe 2.1 combo** (one lane, either/or), 2× USB 2.0 | USB3 or PCIe (but see 3.2) |
| Ethernet | 1× 100M EMAC (dropped on REV5) | **2× GbE (GMAC + GMAC200)** | dual gigabit (routing, TSN-style labs) |
| CAN | 2× CAN (mainline-ready) | 2× CAN | same |
| RISC-V | C906 on the die, **eFuse-locked on S3** (works on S4, ~800 MHz, RVV 0.7.1) | **E906, RV32IMAFC, 200 MHz** | an MCU-class core that is *not* locked; **less** capable than the S4's C906 |
| DSP | HiFi4 | HiFi4 | same |

### 3.2 The board

| | T113 boards (MQ-Dual / your REV5) | Avaota-A1 v1.7 |
|---|---|---|
| Storage | SD, SPI NOR/NAND, eMMC (REV5) | eMMC (32 GB retail), **SPI NAND W25N01GV**, microSD |
| USB | USB-C OTG + 1 USB-A | USB-C OTG (**debug UART on the SBU pins**), **USB 3.0 Type-A** + USB 2.0 Type-A (stacked) |
| **PCIe** | — | **none.** The USB3/PCIe combo is wired to the USB3 port (schematic sheet 8; the PCIe refclk is unconnected) |
| Network | RTL8723BS Wi-Fi (mainline staging) | **2× RTL8211F GbE**; **AIC8800D** Wi-Fi 6 / BT 5.4 (SDIO + UART), with **no mainline driver** |
| Display | DSI 7", SPI panels | HDMI, DP (from eDP), LVDS/MIPI connector, 50-pin RGB FPC, 1.14" SPI TFT (ST7789V) |
| Camera | DVP | 4-lane MIPI CSI connector |
| CAN | CAN0 fitted (REV5) | **TJA1051T transceiver fitted** |
| Power | USB-C 5 V | **12 V DC barrel** (TPS54531 buck), AXP717 + AXP323 PMICs, fan header |
| Debug | microSD JTAG, CH347F | microSD JTAG (same pins), PB JTAG on the FPC, E906/HiFi4 JTAG on the 40-pin header (1.2) |
| Recovery | FEL | FEL button |

### 3.3 Mainline Linux and boot chain, side by side

| | T113 (your 6.18 / 7.3-rc work) | Avaota-A1 (torvalds master, read 2026-10-28) |
|---|---|---|
| Boot chain | BROM → U-Boot SPL (open DRAM init) → U-Boot → Linux in Hyp; PSCI from U-Boot (ARMv7) | BROM → U-Boot SPL (open DRAM init, 2025) → **TF-A BL31** → U-Boot → Linux. **Upstream TF-A has no sun55i platform** (`plat/allwinner` has a64, h6, h616, a133, r329 only), even though U-Boot's sunxi docs require BL31 on 64-bit SoCs. Find out which BL31 Avaota/Armbian images use. |
| **Enabled in the board DT** | most of the SoC (your camera, G2D, DSI, VE, audio, CAN, crypto…) | UART0, MMC0/2, SPI NAND, USB 2.0 (OTG + EHCI/OHCI), **GMAC0 + GMAC1**, **Mali GPU**, LEDs, IR, RTC, AXP717/AXP323, pinctrl |
| **Missing in mainline** | cpufreq, suspend-to-RAM, PWM, Falcon from NOR; thermal from 7.0, watchdog enable from 7.2 (your report) | **thermal** (posted 2025, not in master), **cpufreq/OPP**, **display** (DE/TCON/HDMI/DSI/eDP/LVDS), **camera/ISP**, **video engine**, **USB3**, **CAN**, **PWM**, **audio codec**, **CoreSight**, Wi-Fi, the NPU on this board (node exists, not enabled) |
| PREEMPT_RT | 32-bit ARM needs v7.1 (`ARCH_SUPPORTS_RT`) | **arm64 has had it since 6.12** |
| Virtualisation | **none** (KVM for 32-bit ARM was removed from Linux in 5.7) | **KVM on arm64** with GICv3: VMs, containers |
| Same-SoC boards in mainline | — | Orange Pi 4A (T527), Radxa Cubie A5E (A527), X96Q Pro+ (H728) |

### 3.4 Trace: does the T527 trace like the i.MX95?

**On paper, partly. Not proven.**

- The T527 UM says every A55 has an **ETM** and that the CPU subsystem includes CoreSight SoC-600 and a timestamp module. That is the *source* side.
- The manual documents **no trace sink**: no ETF/ETB, no ETR, no TPIU, no funnel or ROM-table addresses.
- Mainline has no CoreSight nodes for the A523 family.
- Without an on-chip sink, the ETM is useless on this board, because there is no trace port on the pins either.
- **In short: "documented ETM" means only "the A55 cores were built with their ETM option".** The i.MX95 RM documents the *whole path*: per-core ETM at +0x30000, funnels, ETF 16 KB at `0x41030000`, ETR at `0x41040000` into DRAM, and no TPIU. That path is what made your capture work. On the T527 only the first box is on paper. The A733 manual does not even mention ETM.
- **What works without any sink:** JTAG halt/step/watchpoints, and **PC sampling through the PMU (PMPCSR)**. That is your `ocd.sh top` method from the i.MX95, and it needs only the debug APB. It should carry over to the A55 cores of the T527 and A733 `[?]`.

**How to find out** (the method you used on the i.MX95):

1. Attach over microSD JTAG.
2. Run `dap info` and walk the ROM table.
3. Look for TMC components (ETF/ETR) and funnels.

Two caveats:

- The DAP may be ADIv6 (SoC-600), so try `dap create … -adiv6` if ADIv5 fails.
- The mainline T527 DT has no CoreSight nodes, so even if a sink exists, trace would start from the debugger, as on your i.MX95.

**Trace on boards you own or are considering, in this price class:**

| Board | Price | ETM | On-chip sink | Status |
|---|---|---|---|---|
| T113-S3 (elb1) | ~$11 per chip | **no** | — | measured: no instruction trace (your doc 80) |
| **Avaota-A1** (T527) | $54.95 | yes (UM) | **not documented** | `[?]` walk the ROM table; Orange Pi 4A and Cubie A5E have the same silicon |
| **FRDM-IMX93** | ~$71–74 | A55 | SEGGER: "on-chip tracing via trace buffer… requires additional init steps" | likely; not tried |
| FRDM-IMX95 Pro | ~$300 | yes | ETF 16 KB + ETR to DRAM, no TPIU | **proven by you**: 1.58 GiB in 8 s, six cores |

If instruction trace is what you want at this price, **the FRDM-IMX93 you already own is the safer bet**. On the Avaota it is an experiment worth one evening of ROM-table walking.

### 3.5 What the Avaota adds for an embedded Linux BSP engineer

1. **arm64 platform work.**
   - EL3/EL2/EL1, TF-A BL31 and PSCI (CPU on/off, idle, suspend), GICv3, 4-level page tables.
   - Your A7 OS course can grow an AArch64 track. The A55 also runs AArch32, so the A7 labs can be compared on the same chip.
2. **A live upstream target**, the same way the T113 was for you, but with bigger gaps:
   - thermal + cpufreq (DVFS with two clusters, energy-aware scheduling);
   - a TF-A port;
   - USB3, CAN, PWM, the audio codec;
   - the display pipeline (an out-of-tree HDMI port exists for the Orange Pi 4A);
   - MIPI CSI/ISP and the 4K video engine.

   Pick small, board-testable pieces first, like you did on the T113. Some are already posted by others (thermal), so check lore before starting.
3. **A realistic product class.** 4 GB RAM, 2× GbE, USB3, a GPU, an NPU, and 4K video are what industrial gateways and HMIs ship with, unlike 128 MB.
4. **LPDDR4 bring-up** with open SPL code and FEL (section 2).
5. **MIPI CSI-2 + ISP on cheap hardware.** This matches your camera-AI roadmap on the i.MX95, at a fifth of the price, once the driver side exists.

### 3.6 What the T113 still does better

- **Mainline multimedia today:** your CSIC driver, G2D, Cedrus, DSI and audio work. On the Avaota, display, camera and VE all still need the vendor BSP.
- **RISC-V:** the S4's C906 (RV64, vector, ~800 MHz) beats the T527's 200 MHz RV32 E906 for your C906 labs.
- **Small and cheap:** in-package DRAM, USB-C power, a ~$11 chip. It is the right base for a sold learning board (elb1); the Avaota is the step up.
- **Proven tooling:** the T113 has JTAG, OpenOCD target, `jtag-fel.sh`, measured numbers and 80+ field docs. The Avaota starts from zero, apart from section 1.

### 3.7 Orange Pi 4A: the same T527, a different board

**Sources:** mainline Linux `sun55i-t527-orangepi-4a.dts` and U-Boot `configs/orangepi_4a_defconfig` (master, read 2026-10-28); the CNX Software spec list; the out-of-tree `ut-slayer/orangepi-4a-mainline` project. `[?]` = not checked on hardware.

**Board hardware:**

| | Avaota-A1 | Orange Pi 4A |
|---|---|---|
| Price | $54.95, 4 GB + 32 GB eMMC included | launch price **$35 (2 GB) / $40 (4 GB)**; the eMMC is an optional module |
| RAM | 4 GB LPDDR4 (VCC-DRAM 1.16 V) | 2 or 4 GB LPDDR4/4X (VCC-DRAM 1.16 V in the mainline DT) |
| Storage | 32 GB eMMC, SPI **NAND**, microSD | eMMC **socket** (16–128 GB modules), SPI **NOR** 128 Mbit, microSD, **M.2 M-key NVMe** |
| The USB3/PCIe lane | **USB 3.0** port | **PCIe 2.0 x1 → M.2 NVMe**; all 4 USB-A ports are USB 2.0 |
| Ethernet | **2× GbE** (RTL8211F) | 1× GbE (YT8531, GMAC1) |
| Wi-Fi/BT | AIC8800D: **no mainline driver** | **AP6256** (brcmfmac + BCM4345C5): **mainline drivers exist and are in the DT** |
| Display / camera | HDMI, DP, LVDS/DSI connector, RGB FPC, SPI TFT; 4-lane CSI | HDMI 2.0, 4-lane DSI, eDP; 4-lane + 2-lane CSI |
| CAN | TJA1051T fitted | not listed |
| Power, size | 12 V barrel; larger board | **5 V/5 A USB-C**; **89 × 56 mm**, Pi layout and 40-pin header |
| Buttons, debug | FEL, reset, power; UART on the header and USB-C SBU | Boot, reset, power; 3-pin debug UART |
| microSD JTAG | PF0–PF5 (SDC0) | **the same pins**: `mmc0` = PF0–PF5, card detect on PF6, so your sniffer + CH347F fit `[?]` |
| Design files | **open hardware**: schematic, PCB (Altium/EasyEDA), Gerbers, BOM, LPDDR4 layout templates, IBIS | a schematic PDF from Orange Pi; no layout files `[?]` |

**Software:**

| | Avaota-A1 | Orange Pi 4A |
|---|---|---|
| Mainline Linux, board DT | UART, MMC, SPI NAND, USB 2.0, **2× GbE**, GPU, LEDs, IR | UART, MMC, SPI NOR, USB 2.0, 1× GbE, GPU, **Wi-Fi + BT** |
| Mainline U-Boot | `avaota-a1_defconfig` (2025-07) | `orangepi_4a_defconfig` (2025-10, by the sunxi maintainer Chen-Yu Tsai) |
| Out-of-tree mainline work | — | `orangepi-4a-mainline` on 6.18.55: **HDMI KMS, PCIe NVMe (2 testers), Panfrost devfreq, VPU decode, audio** |

**What this means for your three goals:**

- **DDR training: about equal, and better if you own both.** Both use the same open SPL DRAM driver with the same `TPR10 = 0x802f3333`. The board-specific delays differ:

  | | Avaota-A1 | Orange Pi 4A |
  |---|---|---|
  | `TPR11` (write DQ) | `0xc7c5c4c2` | `0xc6c4c2c0` |
  | `TPR12` (read DQ) | `0x3533302f` | `0x3a373233` |
  | `TPR2` | default | `0x5f090503` |

  Same SoC and same driver, but two layouts give two sets of delays, which makes a clean experiment. Only the Avaota has the open PCB, DRAM templates and IBIS models to explain *why*.
- **BSP and upstream: the Orange Pi 4A.**
  - It is cheaper and easy for you to buy, Pi-sized and USB-C powered.
  - Its Wi-Fi works with mainline drivers.
  - It has PCIe/NVMe hardware, and the A523 PCIe controller is not upstream yet.
  - The sunxi maintainer runs it himself, so patches get tested.
  - An out-of-tree tree already has HDMI, PCIe, VPU and audio working, which is a reference for upstreaming, if you coordinate with its author.
- **Trace and JTAG: the same.** It is the same silicon (3.4) and the same microSD pins.

**Recommendation:**

- **If you buy one T527 board for BSP work, take the Orange Pi 4A 4 GB.**
- **Add the Avaota-A1 later**, or now if DDR/SI is the focus, for its open hardware files, 2× GbE, USB3 and CAN.
- **With both,** you get the same-SoC DRAM comparison above for about $95.

**Does the Avaota-A1 still teach anything the Orange Pi 4A doesn't?** Only a little, and you already have most of it:

- **Its open design files:** schematic, PCB, LPDDR4 layout templates, IBIS. These are useful for your own board design and for DDR/SI. They are **already in this repo** (`1.hardware/Avaota-A1`), so you get that lesson without buying the board.
- **2× GbE, USB 3.0, and a CAN transceiver fitted.** Buy the Avaota only if you want those on the bench.

### 3.8 Orange Pi Zero 4: a different chip, the Allwinner A733

**Sources:**

- CNX Software and LinuxGizmos, 2026-08-31;
- the A733 datasheet V1.01 in `2.docs/docs/A733`;
- the mainline Linux and U-Boot trees, read 2026-10-28;
- SyterKit `soc/sun60iw2/lib/libdram-lpddr{4,5}.a`, inspected with `readelf`.

**The chip and the board:**

| | Orange Pi 4A (T527) | Orange Pi Zero 4 (A733) |
|---|---|---|
| CPU | 8× A55 up to 1.8 GHz | **2× A76 + 6× A55**, up to 2.0 GHz |
| GPU / NPU | Mali-G57 MC1 (Panfrost) / 2 TOPS | **IMG PowerVR BXM-4-64** (not Mali) / 3 TOPS |
| Small cores | E906 RISC-V + HiFi4 DSP | E902 RISC-V |
| DRAM | LPDDR4/4X, 2/4 GB | **32-bit LPDDR4 / LPDDR4X / LPDDR5**, up to 16 GB, depending on the variant |
| Storage | eMMC socket, SPI NOR, microSD, M.2 NVMe | eMMC **or UFS 3.0** (by variant), microSD |
| I/O | HDMI 2.0, 1× GbE, Wi-Fi 5, 4× USB 2.0, M.2 PCIe 2.0 | mini-HDMI, **USB-C DP**, GbE, **Wi-Fi 6 / BT 5.4**, 2× MIPI CSI, **PCIe FFC** (Pi-5 style; SoC has PCIe 3.0) |
| Size, price | 89 × 56 mm; $35 / $40 at launch | **55 × 50 mm; from $26.5** (the lowest RAM); one reader saw 4 GB at ~$52 |

**Mainline status:**

| | Orange Pi 4A (T527) | Orange Pi Zero 4 (A733) |
|---|---|---|
| Linux | board DT, GPU, GbE, Wi-Fi; out-of-tree HDMI/PCIe | PCK600 and RTC clock in v7.3; pinctrl on master for 7.4. **Main clock driver (CCU) v6 in review.** SoC `.dtsi` posted as v1 (Cubie A7S, June 2026), not merged. **No Orange Pi board DT.** The PMIC driver (vendor AXP8191 = mainline AXP318W) is at v8, not merged yet (3.11). |
| U-Boot | `orangepi_4a_defconfig`, open SPL DRAM init | "initial A733 support" v3 (January 2026), **no DRAM init**, not merged |

**The DDR surprise, which matters for your i.MX95 work.** The A733's `libdram` is a **Synopsys DWC DDR PHY** driver, the same model as NXP:

- **It is unstripped.** It has 52 named functions: `dwc_ddrphy_phyinit_D_loadIMEM`, `dwc_ddrphy_phyinit_F_loadDMEM`, `dwc_ddrphy_phyinit_G_execFW`, `lpddr5_phyinit_I_loadPIEImage`, `ddrphy_phyinit_C_initPhyConfigPsLoop`, `dwc_ddrphy_phyinit_progCsrSkipTrainPsLoop`, `save_phy_2d_training_result`.
- **It embeds the PMU training firmware** as named data objects:
  - `imem_lpddr5`: **64,160 bytes**
  - `imem_lpddr4`: 51,672 bytes
  - `dmem_lpddr5`, and PIE images `pie1…4_lpddr5`
- **It looks like the i.MX95's PHY generation, not the i.MX93's.** The i.MX95 OEI has the same PState-loop and `prog_csr` structure and the same 64 KB IMEM window (2.17). Likely, but not proven.
- **Your i.MX95 PMU reverse engineering transfers more directly here than to the i.MX93.** Confirmed on 2026-10-28 in [4.a733-ddr](4.a733-ddr/README.md):
  - the PHY sits at `0x0A900000`;
  - IMEM/DMEM are at `0x50000`/`0x58000`, as on the i.MX95;
  - the message-block defaults match NXP FW2024.09 at the same addresses;
  - Allwinner's suspend-retention list contains **5,671 of the 5,698** CSRs in NXP's i.MX95 LPDDR5 trained-CSR list.
  - **Still to do on the other PC:** compare `imem_lpddr5` byte for byte with NXP's `lpddr5_imem_v202409.bin`. Byte-identical would mean the same release.
- **Unlike NXP, even the host-side code (load, run, read results) is a closed blob here.** An open A733 DRAM init does not exist anywhere, which makes it a real upstream gap.
- The T527 `libdram` has only `ddrphy_phyinit_C_initPhyConfig` and none of the `dwc_ddrphy_*` functions or firmware images. Allwinner borrowed the PhyInit *naming* there, around its own PHY (2.12).

**Verdict for your goals:**

| Goal | Best board | Why |
|---|---|---|
| BSP and upstream, now | **Orange Pi 4A** | mainline base exists; clear gaps to fill (PCIe, display, thermal, cpufreq) |
| DDR and your i.MX95 PMU work | **Orange Pi Zero 3W or Zero 4** (same A733) | Synopsys PMU firmware in an unstripped blob, LPDDR5, FEL. Chosen: **Zero 3W 6 GB** (LPDDR5 on every variant). |

The cost of an A733 board is running the vendor BSP for a while. Mainline work is under way, and a Zero 3W owner can help close the gaps (3.11). Pick an **LPDDR5 variant** for DDR work; every Zero 3W is LPDDR5. The A733 also has the newest cores (A76 + A55).

**Avaota-A1:** use its design files from this repo. Buy it only for 2× GbE, USB3 or CAN.

### 3.9 A733 vs T527 in detail; JTAG, eMMC and UFS on the Orange Pi Zero 4

**Sources:**

- A733 datasheet V1.01 and user manual V1.00, and T527 datasheet V0.95 / user manual V0.94, all in `2.docs`;
- xfel `chips/a733.c`;
- mainline Linux commits (read 2026-10-28);
- the CNX Software board article.

**The chips:**

| | T527 (Avaota-A1, Orange Pi 4A) | A733 (Orange Pi Zero 4) |
|---|---|---|
| CPU | 8× A55, 1.8 / 1.42 GHz clusters | **2× A76 @ 2.0 GHz + 6× A55 @ 1.79 GHz** |
| CPU subsystem | DynamIQ DSU, GIC-600, CoreSight-600; UM says each core has an **ETM** | DynamIQ DSU (L3, RAS, ECC options), GIC-600, CoreSight-600; **the UM does not mention ETM** |
| GPU | Mali-G57 MC1 (Panfrost in mainline) | **Imagination BXM-4-64 MC1** (GLES 3.2, Vulkan 1.3); a different driver stack |
| NPU / DSP / MCU | 2 TOPS / **HiFi4** / E906 RV32 | **3 TOPS** / **no DSP** / E902 |
| DRAM | 32-bit DDR3/DDR4/LPDDR3/LPDDR4/4X, **≤ 4 GB**; Allwinner PHY + CPU soft training | 32-bit **LPDDR4/4X/LPDDR5, ≤ 16 GB**; **Synopsys PHY + PMU firmware** (3.8) |
| Storage | eMMC 5.1, SD 3.0, SPI NOR/NAND | eMMC 5.1, SD 3.0, **UFS 3.0** (Synopsys UFS + UniPro 1.8 + M-PHY 4.1, HS-G4, inline AES-XTS), raw NAND, octal SPI |
| High-speed | USB 3.1 / **PCIe 2.1** combo | USB 3.1 **Gen2** combo with **eDP 1.4b/DP 1.4 or PCIe 3.0** |
| Ethernet | **2× GMAC** | 1× GMAC |
| Display | HDMI 2.0, eDP 1.3, 4+4 DSI, 2× dual LVDS, 2× RGB | HDMI 2.0b, eDP 1.4b/DP 1.4, 2× 4-lane DSI (DSC), LVDS, RGB, E-ink |
| Camera / video | MIPI CSI 4+4 + ISP; 4K60 decode, 4K25 encode | **3× MIPI CSI (4+4+2), ISP 8M@60**; **8K24** H.265/VP9/AVS2 decode, **4K30 H.265/H.264 encode** |
| GPIO layout | `PF_CFG0` at `0x020000F0` | **new layout**: `PF_CFG0` at **`0x02000300`** (GPIO block 8 KB) |
| Mainline | SoC + boards since 6.15 | **foundations only, 2026:** pinctrl (Andre Przywara), MMC/SPI/I2C/NMI bindings and RTC clock (Jerome Brunet), PCK600 power domains (Yuanshen Cao); **no SoC DT yet**, no U-Boot |
| FEL tools | xfel read/write | xfel read/write (chip ID `0x00190300`); `jtag` and `ddr` are **stubs** |

**Does the A733 "crush" the T527?**

- **Hardware and DDR: yes.** It has faster cores, LPDDR5, UFS, PCIe 3.0 and the Synopsys PHY.
- **Mainline today: no.** Upstreaming has only started, but it is real and active, by Arm and BayLibre people. So:
  - **(+)** It is a fresh SoC with serious maintainers. Board DT, MMC/eMMC, UFS glue and an open DRAM init will all be needed.
  - **(−)** For a while you work on the vendor kernel, and your patches depend on others landing the SoC basics first. Check lore before starting anything.
  - The CNX article's "nothing has happened" is out of date.

**JTAG on the A733: yes, with one difference.**

- **The SD-card mapping is the same as on the T527:**

  | microSD contact | A733 pin | Function 3 |
  |---|---|---|
  | DAT1 | PF0 | JTAG-MS (TMS) |
  | CMD | PF1 | JTAG-DO (TDO) |
  | DAT0 | PF3 | JTAG-DI (TDI) |
  | DAT2 | PF5 | JTAG-CK (TCK) |
  | CLK / DAT3 | PF2 / PF4 | UART0 TX / RX |

  The GPIO numbers for CMD and DAT0 are swapped compared with the T527 (where PF1 = DAT0 and PF3 = CMD), but the **same sniffer wiring and CH347F** work.
- **The register moved.** In FEL, first check `xfel read32 0x02000300`; the boot ROM may already mux JTAG. Otherwise run `xfel write32 0x02000300 0x0f3f3f33`. Do **not** reuse the T527 address `0x020000F0`.
- **The PB route (confirmed 2026-10-28).** Use function 7:

  | Pin | Signal |
  |---|---|
  | PB0 | JTAG-MS (TMS) |
  | PB1 | JTAG-CK (TCK) |
  | PB2 | JTAG-DO (TDO) |
  | PB3 | JTAG-DI (TDI) |

  - Sources: A733 datasheet V1.01 pin table, and the `jtag_gpio` field of every Orange Pi sun60iw2 boot0 header.
  - `PB_CFG0` is at `0x02000100` (GPIO banks start at 0x80 with a 0x80 stride).
  - boot0 itself routes these pins to JTAG when the header's `enable_jtag` word (offset `0xCC`) is 1. Orange Pi's generic `boot0_sdcard.fex` already has it set. That gives JTAG during DRAM training while the board boots from SD; see [4.a733-ddr](4.a733-ddr/README.md).
  - On the Zero 3W/Zero 4 these pins are UART2 (PB0/PB1) and I2C0 (PB2/PB3), probably on the 40-pin header `[?]`.
  - The CPUS (S-JTAG) is on PL4–PL7, and the RISC-V ARISC's own JTAG (S-RJTAG) is on PM0/PM1. `JTAG-SEL` is ball W2.
- **The DAPs (from SyterKit's `scripts/openocd/allwinner_a733.cfg`):**
  - two TAPs, big cluster IDCODE `0x5ba00477` and little cluster `0x2ba06477`;
  - both **ADIv6** (CoreSight-600);
  - each has an APB-AP (`0x1000`) and an **AHB-AP (`0x2000`)** for system-bus reads without halting a core.
  - Core debug bases are `0x09010000` + core × `0x100000`.
  - You need OpenOCD master: it has both the CH347 driver and ADIv6 support.
- **Unverified on the Zero 4:**
  - that its microSD is wired to SDC0 (normal for Allwinner);
  - how FEL is entered (the board has "BOOT" through-holes, no button);
  - whether any trace sink exists.

**eMMC and UFS: good teaching, in two very different sizes.**

- **eMMC:** the A733 MMC compatible strings are already in mainline (2026-08). Board-level eMMC bring-up (DT, HS200/HS400 tuning, boot partitions) is near-term, normal BSP work, and every product needs it.
- **UFS:** the A733 UFSHC is Synopsys UFS 3.0 + UniPro 1.8 + M-PHY 4.1 with inline encryption. Linux has the UFS core and DesignWare helpers, but **no Allwinner glue driver**. That makes it a real driver project (clocks, resets, M-PHY setup, inline crypto). It is rarer in industrial products than eMMC, but growing (automotive, high-end).
- **The boot ROM boots UFS too.** The A733 UM boot order ends `… SPI_NOR → SPI_NAND → UFS`, so it is also a boot-chain lesson.
- **Empty footprints mean BGA soldering** (153-ball class parts, fine pitch), the same skill problem as the DRAM swap (2.8). If you want to *learn the bring-up* rather than the soldering, buy a variant with eMMC or UFS fitted, or check whether the "UFS module footprint" is a plug-in socket.

**Moving the RAM from the FRDM-IMX95 to the Zero 4: don't.**

- It means desoldering LPDDR5 from a ~$300 board.
- The package and rank setup would have to match, which is unverified.
- Training results belong to a *board* (its layout), not to a chip, so moving the chip moves nothing you can reuse.

**What carries over is the firmware knowledge.** So start on the A733 board, which is cheap and FEL-recoverable:

1. Extract `imem_lpddr5` from `libdram` and compare it with your i.MX95 work.
2. Run training on both boards and compare their message blocks and trained CSRs.
3. On the A733, the *host* side runs in boot0 on the CPU, so JTAG can catch it there, like SPL on the i.MX93 (2.12).

### 3.10 Orange Pi Zero 3W vs Zero 4 (both A733) for RAM, eMMC and UFS rework

**Sources:** CNX Software (Zero 3W 2026-04-15, Zero 4 2026-08-31), the thinkdifferent.blog Zero 3W review, Amazon/Newegg listings. This table was written from articles; the schematics were not checked for it. `[?]` = from articles only.
- **Update 2026-10-29:** Orange Pi's own documents are now local in `2.docs/orangepi-a733/` (git-ignored; `3.a733-android-farm/scripts/00-fetch-sources.sh opi`):
  - Zero 3W: schematic V1.2, user manual v1.0.
  - Zero 4: schematics V1.0 and V1.5, user manual v1.0.
  - 4 Pro: schematic V1.3.2, user manual v1.4.
- Both manuals list eMMC (8/16/32 GB) and UFS (32/64/128 GB) as **optional, not fitted by default**.
- The Zero 4 V1.5 schematic shows a PWM-switched fan header (`FAN_EN_PWM`), the YT8531C PHY and the AXP318.
- **eMMC on the farm boards (2026-10-29):**
  - A 16 GB chip costs 0.55 tr locally, and 16 GB holds 2 instances with room to spare.
  - `3.a733-android-farm/scripts/16-build-emmc-dtb.sh` builds eMMC device trees for both the Zero 3W and the Zero 4.
  - Flash wear is the open question (farm README 8.4).
- Orange Pi also publishes Android images: Android 13 for the Zero 3W and 4 Pro, **Android 16 for the Zero 4** (DDK 25.1, kernel 6.6.102). Farm README section 17 covers them.

**The boards:**

| | Orange Pi Zero 3W | Orange Pi Zero 4 |
|---|---|---|
| Size | **65 × 32 × 1.2 mm** (Pi Zero size) | 55 × 50 mm |
| RAM | **LPDDR5 on every variant**, 4800 MT/s; 1/2/4/8/12/16 GB | LPDDR4 / 4X / **or** LPDDR5, depending on the variant (not stated which) |
| eMMC | footprint, **unpopulated by default** | footprint (8/16/32 GB options) |
| UFS 3.0 (2-lane) | footprint, **unpopulated by default** | "UFS 3.0 module footprint" (32/64/128 GB options) |
| Footprint side | the review's photo caption puts the eMMC and UFS footprints on the **underside** `[?]` | not described |
| Ethernet | **none** | GbE (YT8531C) |
| Other I/O | mini-HDMI, USB-C 3.1 OTG + DP, 4-lane DSI, 2× 4-lane CSI, PCIe 3.0 x1 FPC, Wi-Fi 6/BT 5.4, 40-pin header | mini-HDMI, USB-C 3.1 + DP, 2× 4-lane CSI, PCIe 3.0 x1 FFC, Wi-Fi 6/BT 5.4, 26 + 13-pin headers |
| FEL | "BOOT" through-holes | "BOOT" through-holes |
| Price (launch) | **$25** (1 GB), $35 (2 GB), $50 (4 GB), $60 (6 GB), $80 (8 GB), $99.90 (12 GB) | $26.5 (1 GB), $37 (2 GB), $52 (4 GB), $63 (6 GB), $83 (8 GB) |

**Which one for rework:**

| Rework | Better board | Why |
|---|---|---|
| **RAM swap** | **Zero 3W** | Every variant uses LPDDR5 on the same PCB. You know the memory type, and the footprint already takes 1–16 GB parts. A $25 1 GB board can become a density-upgrade exercise: training plus size detection on the same layout. On the Zero 4 the memory type changes with the variant, so you would first have to find out what your footprint is. |
| **eMMC soldering** | **Zero 3W** (Zero 4 also fine) | Both have the footprint. The 3W's are unpopulated by default and reportedly on the underside, away from the SoC and RAM. |
| **UFS soldering** | **Zero 3W** | A clear "footprint for an optional 2-lane UFS 3.0 module", unpopulated. The Zero 4's wording ("module footprint") still needs checking. |
| Daily BSP development | **Zero 4** | Its Gigabit Ethernet makes TFTP/NFS-root loops easy. The 3W needs USB gadget Ethernet or Wi-Fi. |

**Caveats for the 3W:**

- A tiny, thin board (1.2 mm) heats up fast. That is good for rework, but it **needs a bottom preheater and a holder**, and fine-pitch parts sit close together.
- Check the real footprints (and whether the UFS footprint is BGA) on Orange Pi's schematic or photos before ordering parts.

**Suggested set (updated 2026-10-28):**

- **Bought first: one Zero 3W, 6 GB** (the local shop has no Zero 4 6 GB). It serves:
  - the farm pilot, with a USB-C GbE dongle;
  - the DDR study;
  - the upstream work (3.11).
- Later: a **1 GB Zero 3W ($25) for rework practice** (RAM swap, eMMC/UFS), so the main board stays intact.
- Optional: a Zero 4 when a 6 GB unit is available, for onboard Ethernet in the farm.

**Two 3W boards on the same PCB with different LPDDR5 densities also isolate the *chip* effect on training.** The Avaota-vs-Orange-Pi-4A pair (3.7) isolates the *layout* effect.

### 3.11 A733 upstream status, what a Zero 3W owner can contribute, and Yocto

**Sources (all read 2026-10-28; GPU, PMIC and pinctrl re-checked 2026-10-29, and `3.a733-android-farm/scripts/60-mainline-watch.py` repeats the checks):**
- mainline, linux-next and the sunxi `for-next` tree on kernel.org;
- kernel.org patchwork, the LKML archive and the U-Boot list;
- `meta-sunxi`, Allwinner `meta-tina` and SyterKit;
- the Orange Pi 6.6 kernel DT for the Zero 3W, and Orange Pi's boot0 images (decoded in [4.a733-ddr](4.a733-ddr/README.md)).

**Mainline today:**
- Mainline (v7.3 released; master is in the 7.4 merge window), linux-next and sunxi `for-next` have **no `sun60i` DTS**. Only the five `sun55i` files (A523/T527) exist.
- **U-Boot has no A733 support** (it has the open T527 DRAM driver `dram_sun55i_a523.c`).
- **TF-A master has no `sun55i` or `sun60i` port.**

**Who is upstreaming what:**

| Area | Who | State |
|---|---|---|
| Pinctrl driver + binding | Andre Przywara | on master for **7.4** (not in v7.3); I/O-voltage and withstand fixes in review (2026-10-12/13) |
| PCK600 power domains, RTC clock, MMC binding | Yuanshen Cao, Jerome Brunet | merged |
| DMA | Yuanshen Cao | accepted (2026-08) |
| **Main clock driver (CCU)** | Junhui Liu | **v6 in review** (2026-10-09). Everything else waits on it. |
| UART (8250_dw) | Vinicius Pedrosa | v2 (2026-10-19) |
| Message box | Tim Michals | v2 (2026-09) |
| **SoC `.dtsi` + Radxa Cubie A7S board** | Enzo Adriano | **v1** (2026-06-13): CPUs, GIC, CCU/R-CCU, pinctrl, UART0, SD. See the review notes below. |
| **PMIC AXP318W** (= vendor "AXP8191", main PMIC on A733 boards) | Andre Przywara | **v8** (2026-09-10): MFD, regulators, binding. Patchwork marks the MFD/regulator patches "handled-elsewhere" (picked up by the maintainer, most likely). Not in mainline or linux-next on 2026-10-29. The U-Boot series also supports it, and notes it is called "AXP819" in vendor PMU code. Earlier versions of this README said "nobody": that was wrong, because the search used only the vendor name. |
| U-Boot "initial A733 support" | Yixun Lan | v3 (2026-01), **no DRAM init**, not merged |
| SyterKit (open bootloader) | YuzukiHD / SamulKyull | Cubie A7A and A7Z ports (2026-09): DRAM via the vendor blob, then an app; no Linux boot yet |
| UEFI (EDK2) for the Orange Pi 4 Pro | vehoelite (`github.com/vehoelite/edk2-a733`, largely AI-written) | out of tree. EDK2 chainloaded by the BSP U-Boot after vendor BOOT0 (DRAM) and TF-A v2.5. Boots Ubuntu 26.04 from NVMe with the BSP kernel; a stock 7.0 kernel boots via EFI but finds no disks. Its "v2" driver plan predates the upstream CCU/MMC/pinctrl/PMIC series above. Useful register notes: USB2 PHY, PCIe + Cadence ComboPHY bring-up logs, CCU snapshots. Note: the 4 Pro's console is UART7 (PL6/PL7) on header pins 8/10, while the Zero 3W uses UART0 on PB9/PB10 (boot0 `uart_debug_port = 0`). |
| GPU (BXM-4-64, BVNC 36.56.104.183) | apercel (community); the **SpacemiT K3** work (same BVNC) | apercel: out of tree, Orange Pi 4 Pro. K3: binding `spacemit,k3-gpu` on master for 7.4 (`16f30811a935`, 2026-10-15); the BVNC is not in `drm/imagination`'s support list yet (load with `exp_hw_support=1`); Imagination's open firmware fw 1.1 exists but is not in linux-firmware main; Mesa docs list the BVNC "in active development"; BayLibre builds a fully open Android 17 on it. Details: [farm README 16.8](3.a733-android-farm/README.md). |
| **Orange Pi Zero 3W** | — | **nothing anywhere** |

Review notes on the Cubie A7S `.dtsi` v1:
- Jernej Škrabec asked to move the UART0 pins into the `.dtsi`.
- Jerome Brunet noted that Radxa's A7S and A7A use a **26 MHz crystal**, while the `.dtsi` hard-codes 24 MHz.
- Enzo is holding v2 until the CCU settles.

**Why an Arm engineer wrote the first sunxi DTS files:**
- The A523 `.dtsi`, Avaota-A1 and Cubie A5E files were one series by **Andre Przywara (@arm.com)** on 2025-03-07. He is also U-Boot's sunxi maintainer.
- The Linux sunxi maintainers are Chen-Yu Tsai, Jernej Škrabec and Samuel Holland. Chen-Yu wrote most later commits and added the Orange Pi 4A himself.
- Allwinner does not upstream its chips, so volunteers and Arm fill the gap. Arm's own motives aren't documented.

**Zero 3W facts a board port needs** (from Orange Pi's vendor DT and boot0):

| Item | Value |
|---|---|
| PMICs | **AXP8191** in the vendor DT = **AXP318W** on the schematic (main; mainline driver at v8, not merged) + **AXP515** (missing in mainline) |
| USB-C | power port = USB 2.0 OTG (UDC, also FEL); second port = USB 3.1 OTG (DWC3) + DP alt mode, behind a **HUSB311** driven as `fcs,fusb302` (mainline driver exists) |
| DRAM | LPDDR5, `dram_clk` 2400 MHz (an 1800 MHz boot0 also exists), `tpr10 = 0x325F0000` |
| Crystal | 24 or 26 MHz `[?]`. The vendor DT defines 19.2/24/26 MHz options. Read it on the vendor image (`grep dcxo /sys/kernel/debug/clk/clk_summary`) or from the schematic. |
| JTAG | PB0–PB3 function 7 (UART2/I2C0 in the DT, probably on the 40-pin header `[?]`); boot0 `enable_jtag` flag |
| Storage | microSD (SDC0); eMMC (SDC2) and UFS footprints unpopulated |
| Boot chain on SD | boot0 at 8 KiB; `boot_package` (`u-boot.fex` + `monitor.fex` BL31 + `scp.fex`) at 16,400 KiB |

**What to contribute, in order:**

1. **Board facts first:** the crystal, a `/proc/device-tree` dump and boot logs from the vendor image.
2. **SyterKit `boards/orangepi-zero3w`.** Copy the Cubie A7Z port and use the decoded LPDDR5 `dram_para`. It's fast and mergeable now, and the first LPDDR5 A733 board in SyterKit.
3. **`Tested-by` on Andre Przywara's AXP318W series** (v8) from the Zero 3W. Don't write a new AXP8191 driver: it is the same part.
   - It blocks every A733 board beyond UART + SD: eMMC/UFS, USB, PCIe and CPU DVFS all need it.
   - First read the chip-ID register over I2C on the vendor image and compare it with the ID in Andre's driver.
   - Cross-check its regulator ranges against the vendor GPL `bsp/drivers/power/regulator/axp2101-regulator.c` (AXP8191 ranges) and SyterKit's `drivers/pmu/axp8191.c`.
4. **`Tested-by`** on the CCU v6 series, and later on the `.dtsi` v2, using the Zero 3W.
5. **`sun60i-a733-orangepi-zero3w.dts`** once the `.dtsi` lands (bindings first, `make dtbs_check`, `b4`, boot logs).
6. **Longer term: A733 DRAM init in U-Boot SPL.** It's the real blocker for a mainline boot.
   - It's the same Synopsys LPDDR5 PHY as the i.MX95.
   - U-Boot's `drivers/ddr/imx/phy` code and binman external-firmware blobs are the model.
   - 4.a733-ddr has the register map, mailbox and flow.

**Yocto: two tracks.**

| | Track A, now: vendor-BSP layer | Track B, later: mainline `meta-sunxi` |
|---|---|---|
| Base | new layer (e.g. `meta-orangepi-a733`), **scarthgap**, same release as Allwinner `meta-tina` | `meta-sunxi` master (`LAYERSERIES_COMPAT = wrynose`) |
| Kernel | Orange Pi `orange-pi-6.6-sun60iw2` + their config + the farm fragment. Yocto builds with `O=`, which breaks the vendor `cedar-ve` Makefile: set `B = "${S}"` or patch it. | `linux-mainline` once the `.dtsi` and board DTS land |
| Boot | prebuilt boot0 + `boot_package` (packed by Allwinner's x86 tool); wic: boot0 at 8 KiB, `boot_package` at 16,400 KiB. Later SyterKit. | U-Boot SPL with open DRAM init + TF-A |
| GPU | `pvrsrvkm` recipe + Linux blobs (libgpu) or the redroid image | `drm/imagination` + Mesa, once the BVNC and firmware are upstream; the SpacemiT K3 (same BVNC) is pushing both |
| Machine | a few lines, plus recipes | a 3-line `orange-pi-zero3w.conf` like `orange-pi-4a.conf` (added by a contributor on 2026-07-30) plus `sun60i.inc` |
| Value | reproducible farm images; a Yocto BSP for a new SoC is good portfolio material | the natural follow-up if you also write the board DTS |

Allwinner's `meta-tina` (`t736-demo`: `AW_CHIP = sun60iw2p1`, `sun60iw2p1_t736_defconfig`, the same U-Boot defconfig Orange Pi uses for the Zero 3W) is a useful template. It isn't usable as is: it pulls sources from the surrounding Tina SDK tree (`${TOPDIR}/../..`) and its bundled GCC 10.3.

### 3.12 Reusable A733 hardware facts from other projects (checked 2026-10-29)

**`vehoelite/edk2-a733`** (EDK2 UEFI for the Orange Pi 4 Pro, BSD-2-Clause-Patent, largely AI-written, register findings checked on their board). Facts worth keeping; read their README and `research/` for the full traces:

| Area | Finding |
|---|---|
| Boot | BROM → vendor BOOT0 (DRAM) → TF-A BL31 v2.5 → BSP U-Boot 2018.07 → EDK2. The DRAM blob stays. The BROM tries SD before SPI-NOR, which matches the A733 manual's boot-select table (`SMHC0 -> SPI0 NOR -> …`), so a bad SPI boot chain falls back to SD. |
| Mainline | A stock Ubuntu 7.0 kernel boots via the EFI stub: 8 CPUs, GICv3, PSCI, `efifb` from their GOP. It then finds no block devices. That is the same gap as section 3.11: no A733 MMC/USB/PCIe drivers yet. |
| Memory map | System RAM `0x40000000–0x1bfffffff` (6 GB). GICv3 distributor `0x03400000`, redistributor `0x03460000`. CCU `0x02002000`, SYSCFG `0x03000000`. |
| SError traps | No SBSA generic watchdog at the architectural address: touching it raises an SError. Reading an **unclocked** PCIe DBI (`0x06000000`) stalls the bus and hangs the boot. Useful for the JTAG/SError notes (section 1). |
| USB2 host | PHY bring-up order (from BSP `sunxi-hci.c`): assert PHY reset (CCU bit 30) → 200 µs → clear FORCE_SUSPEND (`+0x800`) → clear SIDDQ (`+0x810`) → passby/tune (`+0x800`, `+0x818`) → `0x53` to `+0x81C` → deassert reset → 1 ms. `HCI +0x824` bit 3 means "UTMI clock valid", not "device present". Also `SYSCFG +0x160 \|= BIT10` (USB tunnel enable) and `OTG +0x420 &= ~BIT0` (hand the OTG PHY to EHCI0). CCU values are in their table; `research/sun60iw2-ccu-phy-usb-snapshot.txt` is a full register snapshot from a working BSP boot. |
| PCIe | `allwinner,sunxi-pcie-v300-rc` is a DesignWare core: DBI `0x06000000` (size `0x480000`), Cadence combo PHY at `0x06C00000`, which also serves USB3/xHCI.<br>Init order (BSP `pcie-sunxi-plat.c`): regulators (3.3 V, 1.8 V) → `pclk_rst`, `pwrup_rst` → `pclk_aux` → `pclk_slv` **at 400 MHz** → `its` reset and clock → combo PHY → only then touch DBI.<br>**DBI must be read 32 bits at a time;** wide reads return all-ones.<br>iATU: CFG0 at CPU `0x22200000` → bus 1, MEM at `0x22100000` identity.<br>The PCIe master sees DRAM with a **−`0x20000000`** CPU→bus offset; USB EHCI is identity.<br>Gen3 speed change can stall data-link-up; they pin Gen1, while the BSP kernel itself trains Gen3 with a WD SN7100.<br>Relevant for the farm if a PCIe NIC or NVMe goes on the Zero 3W FPC (farm README 8.3). |
| Display | Reprogramming only the DE3.0 mixer0 layer-0 scanout address (`0x05101018`) and pulsing DBUFF apply (`0x05100008`) takes over the BSP-initialised panel. Scanout reads DRAM directly, so CPU writes need a cache clean. |
| Ethernet | After their EDK2 boot the vendor kernel's Ethernet dies. Not solved; they found and fixed an over-written MBUS/AHB master-gate bug (`0xb10103f8` / `0xf0050803` are the vendor values) along the way. |
| Console | Orange Pi 4 Pro: UART7 (R_UART0, PL6/PL7, `0x07080000`) on header pins 8/10, which nothing in the boot chain enables. **The Zero 3W instead uses UART0 on PB9/PB10** (`sys_config.fex` `uart_debug_port = 0`), and boot0 enables it. |

**Other A733 projects on GitHub** (survey 2026-10-29 of about 30 repos; `[U]` = claimed, not shown):
- **Boot chain without boot0:** `DockSeed/a733-bootchain` (Cubie A7S): Radxa's U-Boot `u-boot-dlan17` (v2026.07 + 73 commits) + 17 patches, upstream TF-A + 17 patches (Jernej Škrabec's A733 series), BL31 in SRAM at `0x62000`, no SCP. DRAM is still Radxa's closed `ddr.bin`, called from the SPL (details in `4.a733-ddr` §5b).
- **Kernels:**
  - `DockSeed/a7s-linux-lts`: 6.18.59 + 263 out-of-tree patches (CCU, PCIe RC, display/DP, MMC HS400, IOMMU, thermal), with mainline `powervr` running the A733 GPU on Imagination's open firmware.
  - `nickyg666/orangepi-zero3w-mainline`: Zero 3W on 6.18 with vendor CCU/pinctrl/PMIC drivers; mainline `powervr` + Mesa Vulkan/Zink work; no PCIe. Its 7.3-rc2 builds need `VA_BITS=39`, because the vendor BL31 panics with 52-bit VA.
- **Other UEFI and OS work:** `beg0fthend/edk2-a733` is the original EDK2 port that vehoelite's fork builds on. `0Re0-8192/a733-edk2` + `a733-windows-arm64` claim Windows 11 ARM64 to the desktop from SD `[U]`.
- **Upstream trackers** (`GrecAndrei/sun60iw2-upstream`, `crescenzo77/…`): nothing newer than CCU v6 / DTS v1.
- **`opentina-org/build`:** Allwinner's own mainline-based SDK (U-Boot 2026.01 SPL, TF-A + OP-TEE, Linux 6.18.14). It still needs boot0.

Their "v2" plan (port BSP MMC, then PCIe + combo PHY, then USB PHY to a mainline kernel) overlaps the upstream series in section 3.11: MMC binding merged, CCU v6 and AXP318W in review, pinctrl for 7.4. Anyone working on it should start from those series.

---

### 3.13 Zero 3W eMMC and UFS: which chips fit, and what to prepare for soldering (2026-10-30)

**Sources.** Most facts below come from Orange Pi's Zero 3W schematic V1.2 (`2.docs/orangepi-a733/`):
- page 2: the power tree;
- page 3: `U6`, eMMC;
- page 4: `U8`, UFS;
- page 6: the PMIC;
- page 10: the boot select.

The rest come from the A733 datasheet V1.01, the Orange Pi 6.6 device tree and Allwinner's A523 eMMC support list V1.139 (`2.docs/docs/A523/…`). Nothing here has been soldered yet.

**What the two footprints are:**

| | eMMC (`U6`) | UFS (`U8`) |
|---|---|---|
| Package | BGA153, 11.5 × 13 mm, 0.5 mm pitch, JEDEC eMMC ball map | FBGA153, 11.5 × 13 mm, max 1.0 mm high (`FBGA153_11R5X13R0X1R00`) |
| SoC side | SMHC2, 8-bit, HS200/HS400, eMMC 5.1 | 2-lane UFS 3.0 host, M-PHY 4.1, HS-G1…G4 (driver asks for G4) |
| VCC | 3.3 V, DC-DC1 → SW2 (`VCC_3V3_EMMC`), always on | `VCC_UFS_S0` from DLDO6, labelled **`VCC25-UFS` (2.5 V)** in the power tree. Software-set rail: measure it. |
| VCCQ | 1.8 V, DCDC8's always-on "1.8V" net (`VCC-1V8-EMMC`) | 1.2 V, DCDC9 (`VCC1V2_UFS_VCCQ_S0`) |
| VCCQ2 | – | 1.8 V only through `R1133` "0R/NC" (needed by UFS 2.x only) |
| Small parts on the footprint's rails | VDDI: C257 2.2 µF, C271 100 nF (0201) | VCCQ: C306 and C308 100 nF, C314 1 µF, C315 4.7 µF, C307 10 µF<br>VCCQ2: C312 100 nF, C313 10 µF<br>VCC: C309 100 nF, C310 1 µF, C311 10 µF<br>VDDI/VDDIQ/VDDIQ2: C302–C304 2.2 µF<br>RST_N: C305 1 nF |
| Linux | `sdc2` enabled in the stock tree | `ufs@4520000` enabled in the stock tree |

- **Boot order.** The Zero 3W's `BOOT-SEL-ADC` has only R24 (10 kΩ to AVCC), which puts the pin at 1800 mV. Per the table on page 10 that means: SD card first, then UFS, then the other media.
  - Orange Pi ships `boot0_ufs_orangepizero3w.fex`.
  - `nand-sata-install` has "Boot from eMMC" (2) and "Boot from UFS" (8), manual §3.36/3.37.
  - An SD card with a system on it always wins. Remove it to boot from the soldered chip.
- **Both footprints can be fitted at once.** They are separate parts on separate buses.
- **Correction for our eMMC device tree.**
  - The vendor DT comment names `reg_cldo1` for the eMMC 1.8 V. On these boards the eMMC's 1.8 V is DCDC8. On the Zero 4, DCDC8 also feeds the LPDDR5 1.8 V rail, and `CLDO1` is unused.
  - `scripts/16` no longer sets `vqmmc` (farm README 8.4).

**eMMC: parts Allwinner tested on the A523.** These are marked "S/T" (sample fully tested) in the A523 list. The A523 has the same SMHC family as the A733; there is no A733 list. All are eMMC 5.1 (Kingston W525: 5.0) in BGA153 11.5 × 13, and Allwinner labels all of them MLC. MLC lasts much longer than TLC, which matters for the farm's write load (farm README 8.4).

| Size | Samsung | Kioxia (Toshiba) | SanDisk | Kingston |
|---|---|---|---|---|
| 16 GB | **KLMAG1JETD-B041**, KLMAG1JENB-B041 | THGBMHG7C1LBAIL | SDINBDG4-16G-XA (automotive) | EMMC16G-W525 (industrial) |
| 32 GB | **KLMBG2JETD-B041**, KLMBG2JENB-B041 | THGBMHG8C2LBAIL | SDINBDG4-32G | EMMC32G-W525 (industrial) |
| 64 GB | KLMCG4JETD-B041 | THGBMHG9C4LBAIL | SDINBDG4-64G | EMMC64G-W525 |

- Ask the seller of the 0.55 tr chip for its exact part number, and prefer one from this table.
- Allwinner's own verification guide (`2.docs/docs/Product…/Linux_eMMC物料_验证指南.pdf`) tightened its tests because of *拆机料*, salvaged parts on the market.
  - A salvaged chip may already be worn.
  - Read its wear estimate as soon as it runs (`mmc extcsd read`, `LIFE_TIME_EST_TYP_A/B`; `0x01` = 0–10 % used).

**UFS: buy UFS 3.x, with VCC 2.4–2.7 V and VCCQ 1.2 V.** The board gives 2.5 V and 1.2 V, as Allwinner's own demo board does for UFS 3.x ("VCC-UFS 2.5 V, UFS-VCCQ 1.2 V"). There is no Allwinner UFS list here, so check every datasheet.

| Part | What it is | Notes |
|---|---|---|
| Kingston UFS64G-CY14-02N01 | 64 GB UFS 3.1, 2.5 V (2.4–2.7 V), FBGA153 11 × 13 | distributor data; TLC |
| Kingston UFS 3.1, CY14-02J01 family (64/128 GB) | UFS 3.1, VCC 2.4–2.7 V, VCCQ 1.14–1.26 V | Kingston datasheet "UFSnnn CY14 02J01" |
| Kioxia THGJFGG9T15BAA8 / BAB8 | 64 GB UFS 3.1, automotive, VCCQ 1.14–1.26 V | VCC 2.4–2.7 V or 2.7–3.6 V; 1.2 mm high, while the footprint is drawn for 1.0 mm max: check the clearance |
| Samsung KLUDG4UHDB-B2D1 | 128 GB UFS 3.1, common on marketplaces | voltages not confirmed; buy only with a datasheet |
| **Samsung KLUDG4UHGC-B0E1** (checked 2026-10-30) | 128 GB UFS 3.1, G4 2-lane, **"1.2 / 2.5 V"**, 11 × 13 × 0.8 mm, −25…85 °C, mass production | Distributor table (GlobalizeX, 2024-03-19). Samsung's site shows no specs. The body is 0.5 mm narrower than the footprint outline (see below). Siblings: KLUEG8UHGC-B0E1, 256 GB, same data. |

- **UFS 2.1/2.2 parts** (for example Samsung KLUCG4J1ED-B0C1, 64 GB, or Kioxia THGAF8G8T23BAIL, 32 GB) need VCC 2.7–3.6 V plus VCCQ2 1.8 V.
  - On this board that means DLDO6 at 3.3 V and fitting `R1133`.
  - Skip them unless you want that exercise.
- The A733 runs UFS at up to HS-G4 × 2 lanes. That is far beyond what the farm needs. eMMC is the practical farm storage, UFS the learning exercise.

**KLUDG4UHGC-B0E1 is a good fit, if two checks pass.**
- What matches: its 1.2 V and 2.5 V rails and its 2-lane HS-G4 interface are exactly what the Zero 3W's UFS footprint and the A733 host provide.
- **Check 1, the UFS VCC on your board** (C311): it must read 2.5 V.
- **Check 2, the package.** It is 11 × 13 mm against the 11.5 × 13 mm the footprint is drawn for. Samsung's later UFS packages use that narrower body, and I expect the same JEDEC 153-ball map. Before soldering, lay the chip dry on the pads under the microscope, or compare a photo of its balls with the pads. Then align by the balls, not the silkscreen outline. Buy a stencil that lists 11 × 13.
- The same two points apply to the Zero 4, which has the same UFS footprint and rails.

**Buying used Samsung chips (the plan).** Samsung is the most common salvage brand, so this is reasonable. Check:
- **Part number and package**, as above. Only discrete parts: `KLM…` (eMMC) and `KLU…` (UFS). Never `KM…`, the eMCP/uMCP combos.
- **Wear.** Read it right after the first boot and reject a worn chip:
  - eMMC: `mmc extcsd read` → `LIFE_TIME_EST_TYP_A/B`, `PRE_EOL_INFO`.
  - UFS: the health descriptor in sysfs, `…/ufs*/health_descriptor/{life_time_estimation_a,life_time_estimation_b,eol_info}` (Linux ufshcd).
- **Old data and phone configuration.** Wipe the old data with `blkdiscard`.
  - A phone UFS keeps its maker's LUN layout. Phone makers usually lock the configuration descriptor (`bConfigDescrLock`), so it can't be re-partitioned.
  - Linux still sees the big LUN as `/dev/sda`.
  - **Booting from it is less certain**: the A733 boot ROM must find boot0 where the phone's boot LUN setup puts it.
  - Plan to boot from SD or eMMC and use a used UFS as the root/data disk, unless Orange Pi's "Boot from UFS" works on it as is.
- **Wear favours a large used UFS for the farm.** 128 GB of TLC has far more total write budget than 16 GB of MLC: about 8× the capacity at roughly ⅓–½ the cycles per cell. If a used 128 GB UFS 3.1 costs about as much as a new 16 GB eMMC, it is the better farm disk. The condition is that UFS works on board day.

**Datasheets** (`2.docs/storage-datasheets/`, git-ignored; `3.a733-android-farm/scripts/00-fetch-sources.sh storage`, sha256-pinned):
- Samsung eMMC 5.1 `KLM8G1GETF / KLMAG1JETD / KLMBG2JETD / KLMCG4JETD-B041`, Rev 1.1 (TI E2E), and `KLMBG2JETD` Rev 1.21 (readthedocs mirror):
  - VCC 2.7–3.6 V; VCCQ 1.70–1.95 V or 2.7–3.6 V; HS400;
  - 11.5 × 13 × 0.8 mm for 8/16/32 GB, 1.0 mm for 64 GB.
- Kingston UFS 3.1 `UFS64G/UFS128-TX17-GA3A-DK` v1.1 (LCSC):
  - the JEDEC UFS 3.1 FBGA153 ball assignment, VCC 2.5 V ± 5 %, VCCQ 1.2 V, HS-G4 2-lane;
  - 11.5 × 13 mm, 0.8 mm (64 GB) / 1.0 mm (128 GB).
  - Use it as the UFS 3.1 reference.
- **Samsung UFS 3.1 (`KLUDG4UH…`): no datasheet is public.** Samsung releases them under NDA, and its product pages show no specs. The numbers above come from a distributor table.
- The Samsung UFS 2.1 `KLUCG4J1ED-B0C1` sheet is on Arrow's archive (https://static6.arrow.com/aropdfconversion/bdf2cd4578230e91397e04066ac5ecf19bc1e266/klucg4j1ed-b0c1.pdf), which this PC couldn't reach.

**Do not buy:**
- **Combo packages.** eMCP and uMCP put eMMC or UFS and LPDDR in one package: BGA162/221/254/297, for example Samsung `KMxxx`, SK hynix `H9TQ…`/`H9HQ…`. Many phone-salvage chips are these. Only discrete eMMC (`KLM…`, `THGBM…`, `SDIN…`, `MTFC…`, `H26M…`) or discrete UFS (`KLU…`, `THGAF…`/`THGJF…`, `H28U…`) fits.
- **BGA169, 12 × 16 mm eMMC.** Its ball map is a superset, but this footprint is drawn for 11.5 × 13. Not checked here.

**What to prepare:**

| Group | Items |
|---|---|
| Heat | Hot-air station with small round nozzles (8–12 mm). **Bottom preheater** with a board holder, because the board is 1.2 mm thick. K-type thermocouple to check the profile: about 150–170 °C preheat; peak about 235–245 °C for lead-free balls, about 210–220 °C with Sn63/37. |
| Shielding | Kapton tape and aluminium tape over the LPDDR5, SoC, PMIC and connectors. **The SoC and LPDDR5 sit on the other side of the same thin board:** keep the airflow low and the preheat moderate. |
| Pads | Fine iron tip (knife or 1.2 mm bevel), 1.5–2 mm low-residue wick, leaded solder wire, gel no-clean flux (Amtech NC-559 type), 99 % IPA, lint-free swabs. |
| Reballing (salvaged or reused chips) | BGA153 stencil, 0.5 mm pitch (eMMC/UFS 153 sets), reballing jig, 0.30 mm Sn63/37 balls or leaded paste. Leaded balls lower the reflow peak, which protects the BGAs on the other side. |
| Small parts, if the footprint's own are missing | 0201 X5R capacitors: 100 nF, 1 µF, 2.2 µF, 1 nF. 0402: 4.7 µF, 10 µF. A 0201 0 Ω for `R1133`, only for UFS 2.x. |
| Inspection | Stereo microscope (7–45×), ESD mat and strap, tweezers, multimeter. A bench supply with a current readout for the first power-up. |

**Steps:**
1. **Before soldering.** Boot the stock Debian from SD.
   - Check whether the passives in the table above are fitted on your board, and photograph both sides.
   - Measure the rails on the capacitor pads:
     - eMMC VCC 3.3 V, VCCQ 1.8 V;
     - UFS VCC: **expect 2.5 V, record the value**;
     - UFS VCCQ 1.2 V;
     - UFS VCCQ2 only if R1133 is fitted.
   - **Don't fit a UFS 3.x chip if the UFS VCC reads 3.3 V.**
   - Orange Pi's placement drawing ("Position Diagram", same Drive folder as the schematic) shows where `U6` and `U8` sit. The download was over its quota on 2026-10-30.
2. **Solder.** Apply flux, align by the silkscreen corner and pin 1, and let the chip self-align at reflow. Don't push it.
3. **First power-up.** Use the bench supply: 5 V, and watch the current against the board without a chip. Then:
   - eMMC: `dmesg | grep mmc`, `cat /sys/kernel/debug/mmc*/ios` (look for `mmc HS400`), and `sudo mmc extcsd read /dev/mmcblkN | grep -iE 'LIFE|EOL'`.
   - UFS: `dmesg | grep -i 'sunxi ufs'` should show `gear=[4, 4], lane[2, 2]`; the device is `/dev/sda`.
   - If HS400 gives CRC errors (hand-soldered parts can), drop to HS200: remove `mmc-hs400-1_8v` from `sdc2`. Allwinner's verification guide says HS400 at 200 MHz needs its own validation.
4. **Test, then install.**
   - Test: `fio` random 4K and sequential reads and writes, then a long write/verify pass. That is the core of Allwinner's verification guide; the rest is reboot and standby loops and temperature runs.
   - Install: `sudo nand-sata-install` → 2 (eMMC) or 8 (UFS).
   - For the farm boards, run `55-storage-report.sh` after a day.

## 4. Sources

Local (this repo):

- [Schematic v1.7](<1.hardware/Avaota-A1/hardware/v1.7/01_SCH/SCH_Avaota Pi A_2_2024-08-30.pdf>): sheet 3 (power), 4 (FEL, JTAG-SEL, boot straps), 6 (PB/PF), 7 (PL/PM), 9 (microSD, 40-pin header, RGB FPC). The JTAG nets are also present in schematics v1.2–v1.6.
- [BOM v1.7](<1.hardware/Avaota-A1/hardware/v1.7/04_BOM/BOM_Avaota Pi A_PCB1_2024-08-17.xlsx>)
- [A527 User Manual V0.97](<2.docs/docs/A527/Hardware硬件类文档/芯片手册/A527_User_Manual_V0.97.pdf>): §3.2 DRAMC, §8.6 GPIO (`PF_CFG0`), §9.1.4 secure debug
- [A527 Datasheet V0.96](<2.docs/docs/A527/Hardware硬件类文档/芯片手册/A527_Datasheet_V0.96.pdf>), [T527 Datasheet V0.95](<2.docs/docs/T527/Hardware硬件类文档/芯片手册/T527_Datasheet_V0.95.pdf>): JTAG signals, JTAG-SEL
- [A527 hardware design guide V1.2](<2.docs/docs/A527/Hardware硬件类文档/硬件设计/设计指南/A527硬件设计指南_V1.2.pdf>): JTAG-SEL table, §2.9 Debug
- [T527&T536 DRAM eye-adaptive guide V2.2](<2.docs/docs/T527/Hardware硬件类文档/硬件设计/DDR眼图自适应文档/T527&T536 Dram数据眼图自适应客户指导V2.2.pdf>)
- [DRAM compatibility test guide V1.21](<2.docs/docs/T527/Hardware硬件类文档/硬件物料清单/DRAM兼容性测试指南V1.21.pdf>)
- [Linux SPL-PUB guide](<2.docs/docs/Software 软件类文档/SDK模块开发指南/Others/Linux_SPL-PUB_开发指南.pdf>) (boot0 flow), [Tina config guide](<2.docs/docs/Software 软件类文档/基础组件开发指南/Sundry/Tina_Linux_配置_开发指南.pdf>) (`[jtag_para]`), [Tina security guide](<2.docs/docs/Software 软件类文档/基础组件开发指南/SECURE/Tina_Linux_安全_开发指南.pdf>) §9.5

Upstream:

- xfel: [chips/a523_a527_t527.c](https://github.com/xboot/xfel/blob/main/chips/a523_a527_t527.c), [chips/r528_t113.c](https://github.com/xboot/xfel/blob/main/chips/r528_t113.c)
- SyterKit: [boards/avaota-a1](https://github.com/YuzukiHD/SyterKit/tree/main/boards/avaota-a1), [drivers/dram/dram-sun55iw3.c](https://github.com/YuzukiHD/SyterKit/blob/main/drivers/dram/dram-sun55iw3.c)
- U-Boot: [dram_sun55i_a523.c](https://github.com/u-boot/u-boot/blob/master/arch/arm/mach-sunxi/dram_sun55i_a523.c), [avaota-a1_defconfig](https://github.com/u-boot/u-boot/blob/master/configs/avaota-a1_defconfig), [A523 DRAM patch (v2 13/20)](https://lists.denx.de/pipermail/u-boot/2025-July/594555.html)
- OpenOCD: [ch347 driver](https://openocd.org/doc/doxygen/html/ch347_8c_source.html), [allwinner_h618.cfg](https://github.com/openocd-org/openocd/blob/master/tcl/target/allwinner_h618.cfg), [rk3588.cfg](https://github.com/openocd-org/openocd/blob/master/tcl/target/rk3588.cfg)
- NXP: [Config Tools for i.MX (DDR tool)](https://www.nxp.com/design/design-center/development-boards-and-designs/i-mx-evaluation-and-development-boards/config-tools-for-i-mx-applications-processors:CONFIG-TOOLS-IMX), [DDR Tool User Guide (2021, vTSA FAQ)](https://community.nxp.com/pwmxy87654/attachments/pwmxy87654/blog/109/3/DDR%20Tool%20User%20Guide_v10.pdf), [U-Boot ddrphy_train.c](https://git.openwrt.org/project/bcm63xx/u-boot/tree/drivers/ddr/imx/imx8m/ddrphy_train.c), [LPDDR4 PMU binaries thread](https://community.nxp.com/t5/i-MX-Processors/LPDDR4-bin-binaries-for-i-MX8M/m-p/1367577), the i.MX95 RM (chapter 114 DDRC) and FRDM-IMX95 QSG in `~/praxis/imx`
- i.MX board prices: [FRDM-IMX91/91S (element14/Farnell)](https://au.element14.com/nxp/frdm-imx91/frdm-dev-board-arm-cortex-a55/dp/4680634), [FRDM-IMX91S (Farnell FR)](https://fr.farnell.com/nxp/frdm-imx91s/kit-de-dev-frdm-64-bits-arm-cortex/dp/4753107), [FRDM-IMX93 (Future)](https://futureelectronics.com/p/development-tools--microcontroller-microprocessor--multimedia/frdm-imx93-nxp-9193266), [FRDM-IMX93 (DigiKey)](https://www.digikey.ie/en/products/detail/nxp-usa-inc/frdm-imx93/25675806), [MaaXBoard Mini (Avnet)](https://avnet.com/americas/products/avnet-boards/avnet-board-families/maaxboard/maaxboard-mini), [MaaXBoard Mini launch](https://www.businesswire.com/news/home/20200722005209/en/), [FRDM-IMX8MPLUS (Farnell)](https://export.farnell.com/nxp/frdm-imx8mplus/development-board-arm-cortex-a53/dp/4748406)
- TI: [DDR register configuration tool docs](https://dev.ti.com/tirex/content/Processor_DDR_Config_0.10.10.0000/docs/README.html), [DDR-MARGIN-FW](https://www.ti.com/tool/download/DDR-MARGIN-FW), [margin FW is LPDDR4-only](https://e2e.ti.com/support/processors-group/processors/f/processors-forum/1487648/processor-sdk-am62x-ddr-margin-fw-for-ddr4-sdram), [PocketBeagle 2 rev A1 (CNX)](https://www.cnx-software.com/2025/05/22/pocketbeagle-2-rev-a1-board-gets-1-4-ghz-sitara-am6254-quad-core-cortex-a53-cortex-m4f-soc-with-3d-gpu/), [PocketBeagle 2 memory thread](https://forum.beagleboard.org/t/pocketbeagle-2-memory-sizes/40979)
- ST: [STM32MP135F-DK](https://www.st.com/en/evaluation-tools/stm32mp135f-dk.html), [RS Italy price](https://it.rs-online.com/web/p/strumenti-di-sviluppo-per-microcontrollori/2615098), [U-Boot SPL DDR interactive mode](https://wiki.st.com/stm32mpu-ecosystem-v3/wiki/U-Boot_SPL:_DDR_interactive_mode), [DDRCTRL/DDRPHYC DT configuration](https://wiki.st.com/stm32mpu/wiki/DDRCTRL_and_DDRPHYC_device_tree_configuration)
- Jobs: [AMD Memory PHY FW (Austin)](https://www.jobleads.com/us/job/memory-phy-firmware-engineer-ddr-lpddr--austin--eca55330dc134d678816ab0f2c8394cc3), [AMD DDR/LPDDR FW (Bengaluru)](https://www.electronicsforu.com/career/firmware-engineer-ddr-lpddr-amd-bengaluru), [Intel DDR PHY FW](https://intel.wd1.myworkdayjobs.com/External/job/Mexico-Guadalajara/DDR-PHY-Firmware-Engineer_JR0285805), [Cadence principal FW](https://cadence.wd1.myworkdayjobs.com/en-US/External_Careers/job/Principal-Firmware-Engineer_R53293), [Astera Labs DDR FW lead](https://theorg.com/org/astera-labs/jobs/tech-lead-firmware-engine-89478810), [Qualcomm DDR PHY system design](https://bebee.com/us/jobs/ddr-phy-system-design-engineer-san-diego-us-qualcomm-san-diego-ca--t7xk-793302983), [ZipRecruiter DDR PHY engineer](https://www.ziprecruiter.com/Jobs/Ddr-Phy-Engineer), [memory market 2026 overview](https://intuitionlabs.ai/articles/hbm-dram-ai-memory-demand)
- FRDM-IMX93 debug and DDR: [2.docs/jlink-imx93](2.docs/jlink-imx93) (NXP community post, saved), [FRDM-IMX93 user manual UM12181](https://mouser.com/pdfDocs/FRDM-IMX93_UM.pdf), U-Boot [ddrphy_train.c](https://github.com/u-boot/u-boot/blob/master/drivers/ddr/imx/phy/ddrphy_train.c), [ddrphy_utils.c](https://github.com/u-boot/u-boot/blob/master/drivers/ddr/imx/phy/ddrphy_utils.c), [imx9 ddr_init.c](https://github.com/u-boot/u-boot/blob/master/drivers/ddr/imx/imx9/ddr_init.c), [imx93_frdm board](https://github.com/u-boot/u-boot/tree/master/board/nxp/imx93_frdm), TF-A Synopsys PhyInit for STM32MP2: [CSR names](https://github.com/ARM-software/arm-trusted-firmware/blob/master/drivers/st/ddr/phy/phyinit/include/ddrphy_csr_all_cdefines.h), [LPDDR4 message block](https://github.com/ARM-software/arm-trusted-firmware/blob/master/drivers/st/ddr/phy/firmware/include/mnpmusrammsgblock_lpddr4.h)
- A733 mainline and tools (3.9): [Linux commits mentioning A733](https://github.com/torvalds/linux/commits/master?author=&search=a733) (pinctrl: Andre Przywara; MMC/SPI/I2C/NMI bindings, RTC clock: Jerome Brunet; PCK600: Yuanshen Cao), xfel [chips/a733.c](https://github.com/xboot/xfel/blob/main/chips/a733.c), A733 user manual V1.00 (local: §11.2 UFSHC, GPIO `PF_CFG0` @ 0x0300, boot order)
- A733 upstream and Yocto (3.11):
  - Linux:
    - [Enzo Adriano A733/Cubie A7S series](https://lkml.iu.edu/2606.1/12608.html), [Jerome Brunet review](https://lkml.iu.edu/2606.2/11619.html), [Enzo's status repo](https://github.com/crescenzo77/radxa_cubie_a7s_allwinner_a733)
    - [kernel.org patchwork, A733 patches](https://patchwork.kernel.org/api/1.3/patches/?q=a733) (CCU v6 Junhui Liu, UART, pinctrl, msgbox)
    - Linux and U-Boot `MAINTAINERS` (sunxi sections)
  - U-Boot: [Yixun Lan A733 initial support v3](https://lists.denx.de/pipermail/u-boot/2026-January/607466.html), [AXP318W ("AXP819" in vendor code)](https://lists.denx.de/pipermail/u-boot/2026-January/606579.html)
  - PMIC: [AXP318W patches on patchwork](https://patchwork.kernel.org/api/1.3/patches/?q=axp318) (v8, 2026-09-10)
  - GPU (same BVNC on the SpacemiT K3): [K3 binding on patchwork](https://patchwork.kernel.org/api/1.3/patches/?q=k3-gpu), [Mesa PowerVR docs](https://docs.mesa3d.org/drivers/powervr.html), [BayLibre K3 AOSP](https://github.com/BayLibre/android_device_spacemit_k3); everything else in [farm README 15 and 16.8](3.a733-android-farm/README.md)
  - Yocto: [meta-sunxi](https://github.com/linux-sunxi/meta-sunxi) (`orange-pi-4a.conf`, `sun55i.inc`), Allwinner [meta-tina](https://gitlab.com/tina5.0_aiot/product/tina/yocto/meta-tina) (`t736-demo`)
  - SyterKit [boards/radxa-cubie-a7z](https://github.com/YuzukiHD/SyterKit/tree/main/boards/radxa-cubie-a7z), `drivers/pmu/axp8191.c`
  - Orange Pi: kernel `orange-pi-6.6-sun60iw2` (Zero 3W DT: AXP8191 + AXP515, HUSB311), orangepi-build `sun60iw2.conf` (SD/UFS boot layout)
- Orange Pi Zero 3W (3.10): [CNX Software](https://www.cnx-software.com/2026/04/15/orange-pi-zero-3w-an-allwinner-a733-sbc-in-raspberry-pi-zero-form-factor/), [thinkdifferent.blog review](https://www.thinkdifferent.blog/blog/orange-pi-zero-3w-review/), [Liliputing](https://liliputing.com/?p=199280), [Newegg 4 GB listing](https://www.newegg.com/p/3D0-0067-00036)
- Orange Pi Zero 4 / A733 (3.8): [CNX Software](https://www.cnx-software.com/2026/08/31/orange-pi-zero-4-allwinner-a733-sbc-offers-hdmi-usb-c-dp-gbe-wifi-6-pcie-ffc-connector/), [LinuxGizmos](https://linuxgizmos.com/orange-pi-zero-4-with-octa-core-a733-wi-fi-6-and-gigabit-ethernet/), A733 datasheet V1.01 (local, `2.docs/docs/A733`), SyterKit [sun60iw2 libdram](https://github.com/YuzukiHD/SyterKit/tree/main/soc/sun60iw2/lib) and [dram-sun60iw2.c](https://github.com/YuzukiHD/SyterKit/blob/main/drivers/dram/dram-sun60iw2.c), mainline Linux commits for `sun60i` (RTC clock, pmdomain, 2026)
- Orange Pi 4A (3.7): mainline [sun55i-t527-orangepi-4a.dts](https://github.com/torvalds/linux/blob/master/arch/arm64/boot/dts/allwinner/sun55i-t527-orangepi-4a.dts), U-Boot [orangepi_4a_defconfig](https://github.com/u-boot/u-boot/blob/master/configs/orangepi_4a_defconfig) and [its patch](https://lists.denx.de/pipermail/u-boot/2025-October/601491.html), [Linux board series](https://patchew.org/linux/20250628161608.3072968-1-wens@kernel.org), [CNX spec list](https://cnx-software.com/2024/11/16/orange-pi-4a-low-cost-octa-core-sbc-is-powered-by-allwinner-t527-cortex-a55-ai-soc-with-a-2tops-npu), [orangepi-4a-mainline (out of tree)](https://github.com/ut-slayer/orangepi-4a-mainline), [electronics-lab review](https://electronics-lab.com/orange-pi-4a-sbc-powered-by-allwinner-t527-with-mali-g57-gpu-and-2-tops-npu), [linux-sunxi page](https://linux-sunxi.org/Xunlong_Orange_Pi_4A)
- Avaota vs T113 (section 3): mainline [sun55i-a523.dtsi](https://github.com/torvalds/linux/blob/master/arch/arm64/boot/dts/allwinner/sun55i-a523.dtsi), [sun55i-t527-avaota-a1.dts](https://github.com/torvalds/linux/blob/master/arch/arm64/boot/dts/allwinner/sun55i-t527-avaota-a1.dts) and [its history](https://github.com/torvalds/linux/commits/master/arch/arm64/boot/dts/allwinner/sun55i-t527-avaota-a1.dts); TF-A [plat/allwinner](https://github.com/ARM-software/arm-trusted-firmware/tree/master/plat/allwinner); U-Boot [sunxi.rst](https://github.com/u-boot/u-boot/blob/master/doc/board/allwinner/sunxi.rst); [A523 thermal series (2025)](https://lkml.iu.edu/hypermail/linux/kernel/2504.1/08971.html), [A523 NPU node](https://lists.infradead.org/pipermail/linux-arm-kernel/2025-September/1061789.html), [A523 Mali enable](https://lists.infradead.org/pipermail/linux-arm-kernel/2025-July/1042811.html), [Orange Pi 4A out-of-tree mainline port](https://github.com/ut-slayer/orangepi-4a-mainline); T527 datasheet V0.95 / user manual V0.94 (§2.2 CPUX, CoreSight, timestamp) in `2.docs`; schematic v1.7 sheets 1, 8, 10–13 and BOM v1.7; T113 side from `~/1.project/elb1/8.new3-repo/elb1-t113/README.md`, field docs 07, 80 and `4.docs/reports/Embedded Linux industry requirements.md`
- T113-S3 and RZ/V2L: U-Boot [dram_sun20i_d1.c](https://github.com/u-boot/u-boot/blob/master/drivers/ram/sunxi/dram_sun20i_d1.c), [mangopi_mq_r_defconfig](https://github.com/u-boot/u-boot/blob/master/configs/mangopi_mq_r_defconfig), [awboot](https://github.com/szemzoa/awboot); Renesas TF-A [plat/renesas/rz/common/drivers/ddr/ddr.c](https://github.com/renesas-rz/rzg_trusted-firmware-a/blob/v2.3/rzg2l/plat/renesas/rz/common/drivers/ddr/ddr.c), [RZ/V2L DDR params](https://github.com/renesas-rz/rzg_trusted-firmware-a/tree/v2.3/rzg2l/plat/renesas/rz/soc/v2l/drivers/ddr), [RZ/V2L product page](https://www.renesas.com/us/en/products/microcontrollers-microprocessors/rz-mpus/rzv2l-general-purpose-microprocessor-equipped-renesas-original-ai-dedicated-accelerator-drp-ai-12ghz-dual), [SolidRun RZ/G2L·V2L SOM manual](https://solidrun.atlassian.net/wiki/spaces/developer/pages/511148033/RZ+G2L+and+RZ+V2L+SOM+Hardware+User+Manual), [Zephyr RZ/V2L SMARC (boot switches)](https://docs.zephyrproject.org/latest/boards/renesas/rzv2l_smarc/doc/index.html), [SMARC EVK RZ/V2L Linux start guide](https://www.renesas.com/en/document/gde/smarc-evk-rzv2l-linux-start-guide-rev104), OpenOCD [renesas_rz.cfg](https://github.com/openocd-org/openocd/blob/master/tcl/target/renesas_rz.cfg)
- i.MX93 vs i.MX95 DDR internals: U-Boot [imx93-u-boot.dtsi](https://github.com/u-boot/u-boot/blob/master/arch/arm/dts/imx93-u-boot.dtsi), [imx95-u-boot.dtsi](https://github.com/u-boot/u-boot/blob/master/arch/arm/dts/imx95-u-boot.dtsi), [imx95_evk.rst](https://github.com/u-boot/u-boot/blob/master/doc/board/nxp/imx95_evk.rst), [arch-imx9/ddr.h](https://github.com/u-boot/u-boot/blob/master/arch/arm/include/asm/arch-imx9/ddr.h); imx-oei [oei/ddr](https://github.com/nxp-imx/imx-oei/tree/master/oei/ddr) (`ddrphy_train.c`, `ddrphy_utils.c`, `helper.c`, `ddr.h`, `msb_ddr4x.h`, `msb_ddr5.h`, `ddrphy_qb.c`), [mx95lp5 timing](https://github.com/nxp-imx/imx-oei/tree/master/boards/mx95lp5/ddr), [mx95lp4x timing](https://github.com/nxp-imx/imx-oei/tree/master/boards/mx95lp4x/ddr); QuickBoot: [U-Boot QuickBoot doc](https://concept-docs.readthedocs.io/en/latest/board/nxp/quickboot.html), [U-Boot patch series](https://lists.denx.de/pipermail/u-boot/2026-May/620233.html), [NXP community: i.MX95 DDR QuickBoot](https://community.nxp.com/t5/i-MX-Processors/i-MX95-DDR-Quick-Boot-Questions-on-Optimal-Training-Conditions/m-p/2179922); i.MX95 RM ch. 114 (local, `~/praxis/imx/rm`)
- i.MX93 memory: [i.MX 93 Memory Compatibility Guide](https://community.nxp.com/t5/i-MX-Processors-Knowledge-Base/i-MX-93-Memory-Compatibility-Guide/ta-p/1725656), [Micron memory support for NXP (chart)](https://assets.micron.com/adobe/assets/urn:aaid:aem:09a7fea5-83ad-4f34-be20-136408496e91/renditions/original/as/nxp-compatibility-chart.pdf), [AN14012](https://nxp.com/docs/en/application-note/AN14012.pdf), [i.MX 93 product page](https://nxp.com/imx93), [MT53E1G16D1FW-046 AAT:A (DigiKey)](https://www.digikey.at/en/products/detail/micron-technology-inc/MT53E1G16D1FW-046-AAT-A/17632190), [i.MX 95 industrial datasheet](https://www.nxp.com/docs/en/data-sheet/IMX95IEC.pdf), [FRDM-IMX95 Pro LPDDR5-6400 (CNX)](https://www.cnx-software.com/2026/08/11/nxp-frdm-imx95-pro-i-mx-95-board-features-10gbe-faster-6400-mt-s-lpddr5-memory-dual-m-2-expansion/)
- Board: [Pine64 store](https://pine64.com/?p=358314), [Pine64 docs](https://pine64.org/documentation/Yuzuki_Avaota-A1/_full/), [CNX Software article](https://cnx-software.com/2024/04/02/avaota-a1-open-source-hardware-sbc-allwinner-t527-octa-core-cortex-a55-soc), [linux-sunxi JTAG](https://linux-sunxi.org/JTAG), [linux-sunxi microSD breakout](https://linux-sunxi.org/MicroSD_Breakout)
- Local i.MX95 DRAM work (§2.20; outside this repo, not committed yet): the imx95 notes and logs (`~/Project/5.elb1-t113/16.frdm-imx95-pro-jtag/imx95-ddr-training.md`, `logs/ddr-results-20261020.md`, `logs/ddr-oei-training-20261020.txt`, `logs/ddr-phy-fw-arcv2.asm`); the imx-oei mirror (`~/Learning/yocto-imx95/downloads/git2/github.com.nxp-imx.imx-oei.git`, revision `e9bce6f4`); the PRO deploy directory (`~/Learning/yocto-imx95-pro/frdm-imx95-pro-stock/tmp/deploy/images/imx95-19x19-lpddr5-frdm-pro/`); the PRO machine config (`~/Learning/yocto-imx95-pro/sources/meta-imx/meta-imx-bsp/conf/machine/imx95-19x19-lpddr5-frdm-pro.conf`); the board documents `frmd-imx95-pro/UM12527.pdf` and `frmd-imx95-pro/FRDMIMX95PROQSG.pdf` in the imx95 repo.
