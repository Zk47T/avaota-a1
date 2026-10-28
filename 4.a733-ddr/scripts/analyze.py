#!/usr/bin/env python3
"""Reproduce the A733 DRAM-training findings of ../README.md from the vendor files
fetched by 00-fetch.sh. Needs: pyelftools, capstone.

  python3 -E scripts/analyze.py            # report
  python3 -E scripts/analyze.py --csv-out  # also write out/lpddr5_retention_csrs.txt
"""
import collections
import io
import os
import re
import struct
import subprocess
import sys
import tempfile

from capstone import Cs, CS_ARCH_ARM, CS_MODE_THUMB
from elftools.elf.elffile import ELFFile

TOP = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(TOP, "src")
OUT = os.path.join(TOP, "out")
PHY_BASE = 0x0A900000            # APB base of the Synopsys DDR PHY; CSR n at base + 2*n
LIBS = {"tina (Linux SDK v1.5.0)": "dramlib-tina/sun60iw2p1",
        "android (Radxa A733 Android 13)": "dramlib-android/sun60iw2p1"}
BOOT0_DIR = "orangepi-build/external/packages/pack-uboot/sun60iw2/bin"
PARA = ["dram_clk", "dram_type", "dx_odt", "dx_dri", "ca_dri", "para0", "para1", "para2",
        "mr0", "mr1", "mr2", "mr3", "mr4", "mr5", "mr6", "mr11", "mr12", "mr13", "mr14",
        "mr16", "mr17", "mr22", "tpr0", "tpr1", "tpr2", "tpr3", "tpr6", "tpr10", "tpr11",
        "tpr12", "tpr13", "tpr14"]


def csr(addr):
    return (addr - PHY_BASE) // 2


def elf(path):
    return ELFFile(open(path, "rb"))


def symbols(e):
    return {s.name: s for s in e.get_section_by_name(".symtab").iter_symbols() if s.name}


def strings_of(data, minlen=4):
    return [m.decode("latin1") for m in re.findall(rb"[\x20-\x7e]{%d,}" % minlen, data)]


def dmem_writes(e, func):
    """Track literal-pool PHY addresses and immediates; report halfword stores
    into DMEM/CSRs. Good enough for the straight-line message-block setup."""
    sec = e.get_section_by_name(".text." + func)
    d = sec.data()
    md = Cs(CS_ARCH_ARM, CS_MODE_THUMB)
    regs, out = {}, []
    for ins in md.disasm(d, 0):
        ops = ins.op_str
        if ins.mnemonic.startswith("ldr") and "[pc" in ops:
            r = ops.split(",")[0]
            try:
                off = int(ops.split("#")[1].rstrip("]"), 0)
                v = struct.unpack_from("<I", d, ((ins.address + 4) & ~3) + off)[0]
                regs[r] = ("csr", csr(v)) if PHY_BASE <= v < PHY_BASE + 0x400000 else ("imm", v)
            except (IndexError, ValueError, struct.error):
                pass
        elif ins.mnemonic in ("movs", "mov.w", "movw", "mov") and "#" in ops:
            regs[ops.split(",")[0]] = ("imm", int(ops.split("#")[1], 0))
        elif ins.mnemonic.startswith("strh"):
            src = ops.split(",")[0]
            base = ops.split("[")[1].split("]")[0].split(",")
            b = regs.get(base[0].strip())
            offs = int(base[1].strip().lstrip("#"), 0) if len(base) > 1 and "#" in base[1] else 0
            if b and b[0] == "csr":
                sv = regs.get(src)
                out.append((b[1] + offs // 2, sv[1] if sv and sv[0] == "imm" else None))
    return out


def report_libdram():
    print("=" * 78 + "\n1. boot0 DRAM driver (libdram, ARM32, unstripped)\n" + "=" * 78)
    result = {}
    for name, rel in LIBS.items():
        path = os.path.join(SRC, rel, "spl_libdram/libdram")
        if not os.path.exists(path):
            print(f"  missing {path} (run 00-fetch.sh)"); continue
        e = elf(path)
        syms = symbols(e)
        funcs = sorted(n for n, s in syms.items() if s["st_info"]["type"] == "STT_FUNC")
        objs = {n: s["st_size"] for n, s in syms.items() if s["st_info"]["type"] == "STT_OBJECT"}
        blob = open(path, "rb").read()
        ver = next((s for s in strings_of(blob, 5) if re.fullmatch(r"V0\.\d+", s)), "?")
        print(f"\n  [{name}] {ver}, {len(funcs)} functions")
        steps = [f for f in funcs if "phyinit" in f]
        print("   Synopsys PhyInit steps:", ", ".join(steps))
        print("   firmware images:", ", ".join(f"{n}={objs[n]}B" for n in sorted(objs)
                                                if n.startswith(("imem", "dmem", "pie"))))
        print("   save/restore:", ", ".join(f for f in funcs if "save" in f or "SkipTrain" in f))
        # PHY base from save_phy_2d_training_result literal (MicroContMuxSel = CSR 0xd0000)
        d = e.get_section_by_name(".text.save_phy_2d_training_result").data()
        lit = struct.unpack_from("<I", d, len(d) - 12)[0]
        print(f"   MicroContMuxSel literal {lit:#x} -> PHY base {lit - 2*0xd0000:#x}")
        result[name] = dmem_writes(e, "lpddr5_phyinit_F_loadDMEM")
    # compare LPDDR5 message block with NXP i.MX95 LPDDR5 (same PHY family)
    nxp = {}
    tf = os.path.join(SRC, "nxp/mx95lp5_frdm_timing.c")
    if os.path.exists(tf):
        t = open(tf).read()
        i = t.index("ddr_dram_fsp_msg") if "ddr_dram_fsp_msg" in t else 0
        for a, v in re.findall(r"\{\s*(0x58[0-9a-f]{3})\s*,\s*(0x[0-9a-f]+)\s*\}", t, re.I):
            nxp.setdefault(int(a, 16), int(v, 16))
    w = next(iter(result.values()), [])
    print("\n  LPDDR5 message block (DMEM, CSR 0x58000+) written by lpddr5_phyinit_F_loadDMEM:")
    print("   CSR      A733            i.MX95 FRDM (NXP OEI FW2024.09)")
    seen = set()
    for a, v in w:
        if not 0x58000 <= a < 0x58060 or a in seen:
            continue
        seen.add(a)
        print(f"   {a:#07x}  {('%#x' % v) if v is not None else 'computed':14s}  "
              f"{('%#x' % nxp[a]) if a in nxp else '-'}")


def init_dram_logic():
    print("\n  init_DRAM logic (from the disassembly; dram_para word = byte offset / 4):")
    print("""   if (type==LPDDR4 && !(tpr1&BIT31) && !(tpr10&BIT29))   seed para[32..49]=tpr6[6:0] x4, para[50]=mr14 x4
   dram_vol_set(); if (!(tpr13&BIT0)) auto_scan_dram_config();
   mctl_core_init()  ->  mctl_phy_init(): per P-state  C_initPhyConfig, D_loadIMEM, E_setDfiClk,
                         F_loadDMEM, G_execFW (PMU training), I_loadPIEImage
                         if !(tpr10&BIT29): replay para[32..49] into PIE memory (CSR 0xa0d68..)
   if (!(tpr1&BIT31) && (tpr10&BIT29)) {
       save_phy_2d_training_result(): para[32..49] <- DBYTE0-3 lanes 0-8 CSR 0x1x04e/0x1x04f (7-bit)
                                      para[50/51] <- LPDDR5 MR14/MR15 (VREF DQ) ch0/1 rank0/1
       if (!(tpr10&BIT30)) tpr10 &= ~BIT29       # one-shot unless BIT30
   }""")


def report_boot0():
    print("\n" + "=" * 78 + "\n2. Orange Pi boot0 headers (eGON.BT0)\n" + "=" * 78)
    d = os.path.join(SRC, BOOT0_DIR)
    if not os.path.isdir(d):
        print("  missing", d); return
    for f in sorted(os.listdir(d)):
        if not f.startswith("boot0_"):
            continue
        b = open(os.path.join(d, f), "rb").read()
        if b[4:12] != b"eGON.BT0":
            continue
        chk, length = struct.unpack_from("<II", b, 0x0C)
        c = bytearray(b[:length]); struct.pack_into("<I", c, 0x0C, 0x5F0A6C39)
        ok = (sum(struct.unpack_from("<%dI" % (length // 4), c)) & 0xFFFFFFFF) == chk
        w = struct.unpack_from("<32I", b, 0x38)
        en_jtag = struct.unpack_from("<I", b, 0xCC)[0]
        jt = [struct.unpack_from("<8B", b, 0xD0 + 8 * i) for i in range(4)]
        jdesc = " ".join(f"P{chr(64 + g[0])}{g[1]}f{g[2]}" for g in jt if 0 < g[0] < 16)
        ver = next((s for s in strings_of(b, 5) if re.fullmatch(r"V0\.\d+", s)), "?")
        print(f"\n  {f}: libdram {ver}, checksum {'OK' if ok else 'BAD'}")
        print(f"   clk={w[0]} MHz type={w[1]} ({ {8: 'LPDDR4', 9: 'LPDDR5'}.get(w[1], '?') }) "
              f"para1={w[6]:#x} para2={w[7]:#x} mr11={w[15]:#x} mr12={w[16]:#x} mr14={w[18]:#x}")
        print(f"   tpr1={w[23]:#x} tpr6={w[26]:#x} tpr10={w[27]:#x} tpr13={w[30]:#x}  ->"
              f" save2D(tpr10.29)={w[27] >> 29 & 1} keep(tpr10.30)={w[27] >> 30 & 1}"
              f" autoscan_done(tpr13.0)={w[30] & 1}")
        print(f"   enable_jtag@0xcc={en_jtag}  jtag_gpio: {jdesc}")


def report_retention(csv_out):
    print("\n" + "=" * 78 + "\n3. ARISC (RISC-V) standby firmware: PHY retention list\n" + "=" * 78)
    lib = os.path.join(SRC, LIBS["tina (Linux SDK v1.5.0)"], "arisc_liboem/libar100s.a")
    if not os.path.exists(lib):
        print("  missing", lib); return
    with tempfile.TemporaryDirectory() as td:
        subprocess.run(["ar", "x", lib], cwd=td, check=True)
        obj = os.path.join(td, "obj-in.o")
        e = elf(obj)
        syms = symbols(e)
        data = e.get_section_by_name(".data").data()
        funcs = sorted(n for n, s in syms.items() if s["st_info"]["type"] == "STT_FUNC"
                       and re.search(r"save|Load|standby|power|training", n))
        print("  ", e.header["e_machine"], "| functions:", ", ".join(funcs))
        tables = {}
        for n in ("lpddr5_save_addr", "lpddr5_save_addr_mdfs", "lpddr4_save_addr"):
            s = syms[n]
            v = struct.unpack_from("<%dI" % (s["st_size"] // 4), data, s["st_value"])
            tables[n] = [csr(x) for x in v]
            blk = collections.Counter(x >> 12 for x in tables[n])
            print(f"   {n}: {len(v)} CSRs  " + ", ".join(f"{k:#x}000:{c}" for k, c in sorted(blk.items())))
        print(f"   save_data: {syms['save_data']['st_size']} bytes (= {syms['save_data']['st_size'] // 2} x u16)")
        needle = data[syms["lpddr5_save_addr"]["st_value"]:][:64]
    scp = os.path.join(SRC, BOOT0_DIR, "scp.fex")
    if os.path.exists(scp):
        i = open(scp, "rb").read().find(needle)
        print(f"   Orange Pi scp.fex contains lpddr5_save_addr: {'yes @ %#x' % i if i >= 0 else 'no'}")
    tf = os.path.join(SRC, "nxp/mx95lp5_frdm_timing.c")
    if os.path.exists(tf):
        t = open(tf).read()
        i = t.index("ddr_ddrphy_trained_csr[]"); j = t.index("};", i)
        nxp = {int(x, 16) for x in re.findall(r"\{\s*(0x[0-9a-fA-F]+)\s*,", t[i:j])}
        a = set(tables["lpddr5_save_addr"])
        print(f"   vs NXP i.MX95 LPDDR5 ddr_ddrphy_trained_csr: NXP {len(nxp)}, A733 {len(a)}, "
              f"common {len(a & nxp)} ({100 * len(a & nxp) / len(nxp):.1f}% of NXP)")
    if csv_out:
        os.makedirs(OUT, exist_ok=True)
        p = os.path.join(OUT, "lpddr5_retention_csrs.txt")
        open(p, "w").write("\n".join(f"{x:#07x}" for x in tables["lpddr5_save_addr"]) + "\n")
        print("   wrote", p, "(input for a733_dump_trained in a733-ddr.tcl)")


if __name__ == "__main__":
    report_libdram()
    init_dram_logic()
    report_boot0()
    report_retention("--csv-out" in sys.argv)
