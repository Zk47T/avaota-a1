#!/usr/bin/env python3
"""Re-check the A733 / PowerVR upstream status and diff it against the last run.

  python3 -I scripts/60-mainline-watch.py        # prints a table, saves out/mainline-watch/<date>.json

Stdlib only. Sources: kernel.org cgit (torvalds, linux-next), U-Boot (GitHub mirror),
linux-firmware (gitlab.com API), Mesa docs (docs.mesa3d.org), kernel.org patchwork.
lore.kernel.org and gitlab.freedesktop.org are behind a bot check, so they are not used.
"""
import datetime
import json
import os
import re
import sys
import time
import urllib.request

OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "out", "mainline-watch")
UA = {"User-Agent": "a733-mainline-watch/1.0"}
TREES = {"mainline": "torvalds/linux.git", "next": "next/linux-next.git"}


def get(url, tries=4):
    for i in range(tries):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=60) as r:
                body = r.read().decode("utf-8", "replace")
            if "not a bot" in body or "Bad Gateway" in body:
                raise IOError("bot check / gateway")
            return body
        except Exception as e:  # network hiccups and cgit 502s are common
            err = e
            time.sleep(3 * (i + 1))
    return f"__ERROR__ {err}"


def cgit_plain(tree, path):
    return get(f"https://git.kernel.org/pub/scm/linux/kernel/git/{TREES[tree]}/plain/{path}")


def cgit_ls(tree, path):
    html = get(f"https://git.kernel.org/pub/scm/linux/kernel/git/{TREES[tree]}/tree/{path}")
    return sorted(set(re.findall(r">([A-Za-z0-9_.,+-]+\.(?:dtsi?|c|h|yaml))<", html)))


def check():
    r = {}
    for t in TREES:
        dts = cgit_ls(t, "arch/arm64/boot/dts/allwinner")
        r[f"{t}: sun60i DTS files"] = [f for f in dts if f.startswith("sun60i")] or "none"
        clk = cgit_ls(t, "drivers/clk/sunxi-ng")
        r[f"{t}: A733 CCU driver"] = [f for f in clk if "sun60i" in f] or "none"
        pvr = cgit_plain(t, "drivers/gpu/drm/imagination/pvr_device.c")
        bvncs = re.findall(r"PVR_PACKED_BVNC\((\d+), (\d+), (\d+), (\d+)\)", pvr.split("pvr_gpu_support_level", 1)[-1][:1500])
        r[f"{t}: drm/imagination supported BVNCs"] = [".".join(b) for b in bvncs]
        r[f"{t}: 36.56.104.183 in driver"] = "PVR_PACKED_BVNC(36, 56, 104, 183)" in pvr
        yml = cgit_plain(t, "Documentation/devicetree/bindings/gpu/img,powervr-rogue.yaml")
        r[f"{t}: GPU binding allwinner/k3"] = sorted(set(re.findall(r"(allwinner,[a-z0-9-]+-gpu|spacemit,k[13]-gpu)", yml)))
        axp = cgit_plain(t, "drivers/mfd/axp20x.c")
        r[f"{t}: AXP318W in axp20x"] = "AXP318" in axp
        mmc = cgit_plain(t, "drivers/mmc/host/sunxi-mmc.c")
        r[f"{t}: A733 in sunxi-mmc driver"] = "a733" in mmc.lower()
    fw = get("https://gitlab.com/api/v4/projects/kernel-firmware%2Flinux-firmware/repository/tree?path=powervr&ref=main&per_page=100")
    r["linux-firmware powervr/"] = sorted(re.findall(r'"name":"(rogue_[^"]+)"', fw))
    mesa = get("https://docs.mesa3d.org/drivers/powervr.html")
    text = re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", mesa))
    row = text.find("36.56.104.183")
    if row < 0:
        r["Mesa docs 36.56.104.183"] = "not listed"
    else:
        # which table is the row in: the nearest preceding table heading wins
        low = text.lower()
        heads = ["in active development", "not under active development", "partially supported", "unsupported"]
        pos = {h: low.rfind(h, 0, row) for h in heads}
        best = max(pos, key=pos.get)
        r["Mesa docs 36.56.104.183"] = f"listed, table: '{best}'" if pos[best] >= 0 else "listed"
    i = text.find("conformant to Vulkan")
    r["Mesa docs conformance line"] = text[i:i + 150] if i >= 0 else "not found"
    ub = get("https://api.github.com/repos/u-boot/u-boot/contents/arch/arm/mach-sunxi?ref=master")
    r["U-Boot mach-sunxi sun60i/DRAM"] = sorted(set(re.findall(r'"name":"([^"]*(?:sun60i|a733)[^"]*)"', ub))) or "none"
    pw = {}
    for q in ("a733", "axp318", "sun60i", "k3-gpu", "36.56.104"):
        js = get(f"https://patchwork.kernel.org/api/1.3/patches/?q={q}&order=-date&per_page=6")
        try:
            pw[q] = [f'{p["date"][:10]} {p["state"]}: {p["name"][:90]}' for p in json.loads(js)]
        except Exception:
            pw[q] = [js[:80]]
    r["patchwork (newest 6 per query)"] = pw
    return r


def main():
    os.makedirs(OUT, exist_ok=True)
    now = check()
    prev_files = sorted(f for f in os.listdir(OUT) if f.endswith(".json"))
    prev = json.load(open(os.path.join(OUT, prev_files[-1]))) if prev_files else {}
    for k, v in now.items():
        if k.startswith("patchwork"):
            continue
        mark = "  " if prev.get(k, v) == v else "* "
        print(f"{mark}{k:42s} {v}")
    print("\npatchwork:")
    for q, items in now["patchwork (newest 6 per query)"].items():
        old = set(prev.get("patchwork (newest 6 per query)", {}).get(q, []))
        for it in items:
            print(f"  {'NEW ' if prev and it not in old else '    '}[{q}] {it}")
    stamp = datetime.date.today().isoformat()
    json.dump(now, open(os.path.join(OUT, f"{stamp}.json"), "w"), indent=1)
    print(f"\n'*' = changed since {prev_files[-1] if prev_files else 'never'}; saved out/mainline-watch/{stamp}.json")


if __name__ == "__main__":
    sys.exit(main())
