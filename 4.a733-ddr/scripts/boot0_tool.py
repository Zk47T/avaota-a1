#!/usr/bin/env python3
"""Inspect / patch an Allwinner A733 (sun60iw2) boot0 image (eGON.BT0).

  boot0_tool.py show  boot0.fex
  boot0_tool.py patch boot0.fex out.fex --jtag 1                 # boot0 muxes PB0-PB3 to JTAG
  boot0_tool.py patch boot0.fex out.fex --set tpr10=0x325f0000   # any dram_para field
  boot0_tool.py patch boot0.fex out.fex --set dram_clk=1800

Layout (checked on all Orange Pi sun60iw2 boot0 images):
  0x0C checksum, 0x10 length; checksum = sum of u32 words over `length`
  with the checksum field set to 0x5F0A6C39.
  0x38 dram_para[32], 0xB8 uart_port, 0xBC uart_ctrl[2] (8-byte gpio cfg),
  0xCC enable_jtag, 0xD0 jtag_gpio[] (PB0..PB3 function 7 = TMS, TCK, TDO, TDI).
SD card: boot0 lives at 8 KiB (sector 16); Allwinner also reads a backup at 128 KiB.
   sudo dd if=out.fex of=/dev/sdX bs=1k seek=8 conv=notrunc,fsync
Keep the original: the A733 BROM falls back to FEL (USB) if boot0 is broken.
"""
import argparse
import struct
import sys

PARA = ["dram_clk", "dram_type", "dx_odt", "dx_dri", "ca_dri", "para0", "para1", "para2",
        "mr0", "mr1", "mr2", "mr3", "mr4", "mr5", "mr6", "mr11", "mr12", "mr13", "mr14",
        "mr16", "mr17", "mr22", "tpr0", "tpr1", "tpr2", "tpr3", "tpr6", "tpr10", "tpr11",
        "tpr12", "tpr13", "tpr14"]
PARA_OFF, EN_JTAG_OFF, JTAG_GPIO_OFF = 0x38, 0xCC, 0xD0
STAMP = 0x5F0A6C39


def load(path):
    b = bytearray(open(path, "rb").read())
    if b[4:12] != b"eGON.BT0":
        sys.exit(f"{path}: not an eGON.BT0 image")
    return b


def checksum(b):
    length = struct.unpack_from("<I", b, 0x10)[0]
    c = bytearray(b[:length])
    struct.pack_into("<I", c, 0x0C, STAMP)
    return sum(struct.unpack_from("<%dI" % (length // 4), c)) & 0xFFFFFFFF


def show(b):
    stored = struct.unpack_from("<I", b, 0x0C)[0]
    print(f"length {struct.unpack_from('<I', b, 0x10)[0]:#x}, checksum {stored:#010x} "
          f"({'OK' if stored == checksum(b) else 'BAD'})")
    w = struct.unpack_from("<32I", b, PARA_OFF)
    for i, n in enumerate(PARA):
        print(f"  {n:9s} = {w[i]:#010x}" + (f"  ({w[i]})" if n == "dram_clk" else ""))
    t10, t13 = w[PARA.index("tpr10")], w[PARA.index("tpr13")]
    print(f"  -> tpr10.29 save 2D training result = {t10 >> 29 & 1}, tpr10.30 keep saving = {t10 >> 30 & 1},"
          f" tpr13.0 auto-scan done = {t13 & 1}")
    print(f"enable_jtag = {struct.unpack_from('<I', b, EN_JTAG_OFF)[0]}")
    for i in range(4):
        g = struct.unpack_from("<8B", b, JTAG_GPIO_OFF + 8 * i)
        if 0 < g[0] < 16:
            print(f"  jtag_gpio[{i}] = P{chr(64 + g[0])}{g[1]} function {g[2]}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["show", "patch"])
    ap.add_argument("src")
    ap.add_argument("dst", nargs="?")
    ap.add_argument("--jtag", type=int, choices=[0, 1])
    ap.add_argument("--set", action="append", default=[], metavar="FIELD=VALUE")
    a = ap.parse_args()
    b = load(a.src)
    if a.cmd == "show":
        show(b)
        return
    if not a.dst:
        sys.exit("patch needs an output file")
    if a.jtag is not None:
        struct.pack_into("<I", b, EN_JTAG_OFF, a.jtag)
    for kv in a.set:
        k, v = kv.split("=", 1)
        if k not in PARA:
            sys.exit(f"unknown field {k}; one of {', '.join(PARA)}")
        struct.pack_into("<I", b, PARA_OFF + 4 * PARA.index(k), int(v, 0))
    struct.pack_into("<I", b, 0x0C, checksum(b))
    open(a.dst, "wb").write(b)
    show(b)


if __name__ == "__main__":
    main()
