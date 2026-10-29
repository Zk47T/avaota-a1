#!/usr/bin/env python3
"""Static check: will the PowerVR vendor blobs link inside a redroid image?

Models Android's linker namespaces the way linkerconfig sets them up for
Android 13 (API 33):
  sphal  - EGL/GLES/Vulkan drivers, mapper impl, gralloc module and their
           vendor deps, loaded INTO framework processes (SurfaceFlinger, apps).
           May use: /vendor/lib64{,/egl,/hw} + VNDK-SP + LLNDK.
  vendor - vendor executables (allocator service, pvrsrvctl).
           May use: /vendor/lib64{,/hw} + VNDK core + VNDK-SP + LLNDK.
For every blob it resolves DT_NEEDED inside the allowed set, then checks that
every undefined global symbol (and its symbol version) is exported by the
library's dependency closure.

usage: redroid_link_check.py <redroid rootfs> <overlay vendor dir>
       LINK_CHECK_LIBS="lib64/a.so lib64/b.so" also checks dlopen()ed vendor libs
"""
import os
import sys
from elftools.elf.elffile import ELFFile
from elftools.elf.dynamic import DynamicSection
from elftools.elf.gnuversions import GNUVerNeedSection, GNUVerDefSection, GNUVerSymSection

ROOT, OVL = sys.argv[1], sys.argv[2]
APEX_VNDK = os.path.join(ROOT, "system/apex/com.android.vndk.current")


def read_list(name):
    p = os.path.join(APEX_VNDK, "etc", name)
    return {l.strip() for l in open(p) if l.strip()}


VNDK_SP = read_list("vndksp.libraries.33.txt")
VNDK_CORE = read_list("vndkcore.libraries.33.txt")
LLNDK = read_list("llndk.libraries.33.txt")

# Where each kind of library physically lives in the image
LLNDK_DIRS = [os.path.join(ROOT, d) for d in (
    "system/apex/com.android.runtime/lib64/bionic", "system/lib64")]
VNDK_DIR = os.path.join(APEX_VNDK, "lib64")
VENDOR_DIRS = {
    "sphal": ["lib64", "lib64/egl", "lib64/hw"],
    "vendor": ["lib64", "lib64/hw"],
}


class Lib:
    cache = {}

    def __init__(self, path):
        self.path = path
        self.needed, self.undef, self.exports = [], [], {}
        with open(path, "rb") as f:
            e = ELFFile(f)
            dyn = e.get_section_by_name(".dynamic")
            if isinstance(dyn, DynamicSection):
                self.needed = [t.needed for t in dyn.iter_tags() if t.entry.d_tag == "DT_NEEDED"]
            ds = e.get_section_by_name(".dynsym")
            versym = next((s for s in e.iter_sections() if isinstance(s, GNUVerSymSection)), None)
            verneed = next((s for s in e.iter_sections() if isinstance(s, GNUVerNeedSection)), None)
            verdef = next((s for s in e.iter_sections() if isinstance(s, GNUVerDefSection)), None)
            need_names, def_names = {}, {}
            if verneed:
                for _, auxs in verneed.iter_versions():
                    for a in auxs:
                        need_names[a.entry.vna_other] = a.name
            if verdef:
                for v, auxs in verdef.iter_versions():
                    names = [a.name for a in auxs]
                    if names:
                        def_names[v.entry.vd_ndx] = names[0]
            for i, s in enumerate(ds.iter_symbols() if ds else []):
                if i == 0 or not s.name:
                    continue
                bind = s.entry.st_info.bind
                ver = None
                if versym:
                    idx = versym.get_symbol(i).entry.ndx
                    if isinstance(idx, int):
                        idx &= 0x7FFF
                        ver = need_names.get(idx) or def_names.get(idx)
                if s.entry.st_shndx == "SHN_UNDEF":
                    if bind != "STB_WEAK":
                        self.undef.append((s.name, ver))
                elif bind in ("STB_GLOBAL", "STB_WEAK", "STB_GNU_UNIQUE"):
                    self.exports.setdefault(s.name, set()).add(ver)

    @classmethod
    def get(cls, path):
        if path not in cls.cache:
            cls.cache[path] = Lib(path)
        return cls.cache[path]


def locate(name, ns, vendor_root):
    """Return (path, origin) or (None, reason) for a DT_NEEDED name."""
    for d in VENDOR_DIRS[ns]:
        for base in (vendor_root, os.path.join(ROOT, "vendor")):
            p = os.path.join(base, d, name)
            if os.path.isfile(p):
                return p, "vendor"
    if name in LLNDK:
        for d in LLNDK_DIRS:
            p = os.path.join(d, name)
            if os.path.isfile(p):
                return p, "LLNDK"
    allowed_vndk = VNDK_SP | (VNDK_CORE if ns == "vendor" else set())
    if name in allowed_vndk:
        p = os.path.join(VNDK_DIR, name)
        if os.path.isfile(p):
            return p, "VNDK-SP" if name in VNDK_SP else "VNDK"
    if name in VNDK_CORE:
        return None, "VNDK core lib, NOT visible from sphal namespace"
    return None, "not found in allowed namespaces"


SYSTEM_DIRS = [os.path.join(ROOT, d) for d in (
    "system/apex/com.android.runtime/lib64/bionic", "system/apex/com.android.runtime/lib64",
    "system/lib64", "system/apex/com.android.vndk.current/lib64")]


def locate_system(name):
    for d in SYSTEM_DIRS:
        p = os.path.join(d, name)
        if os.path.isfile(p):
            return p, "system"
    if name == "ld-android.so":   # provided by the dynamic linker itself
        return None, "linker"
    return None, "system lib not found"


def check(path, ns):
    problems = []
    order, seen, queue = [], set(), [path]
    origins = {}
    while queue:  # BFS like the linker's load group
        p = queue.pop(0)
        if p in seen:
            continue
        seen.add(p)
        order.append(p)
        in_vendor = p.startswith(OVL) or p.startswith(os.path.join(ROOT, "vendor"))
        for n in Lib.get(p).needed:
            # Namespace rules only constrain vendor libs. LLNDK/VNDK libs resolve
            # their own deps inside the system/vndk namespaces.
            q, why = locate(n, ns, OVL) if in_vendor else locate_system(n)
            if q is None and why == "linker":
                continue
            if q is None:
                problems.append(f"NEEDED {n} (from {os.path.basename(p)}): {why}")
            else:
                origins[n] = why
                queue.append(q)
    exports = {}
    for p in order:
        for sym, vers in Lib.get(p).exports.items():
            exports.setdefault(sym, set()).update(vers)
    missing = []
    for p in order:
        if not p.startswith(OVL):
            continue  # only audit the blobs themselves, system libs are known-good
        for sym, ver in Lib.get(p).undef:
            have = exports.get(sym)
            if have is None:
                missing.append(f"{os.path.basename(p)}: {sym}" + (f"@{ver}" if ver else ""))
            elif ver and ver not in have and None not in have:
                missing.append(f"{os.path.basename(p)}: {sym}@{ver} (have {sorted(v for v in have if v)})")
    return order, origins, problems, missing


def main():
    targets = []
    for d, ns in (("lib64/egl", "sphal"), ("lib64/hw", "sphal"), ("bin", "vendor"), ("bin/hw", "vendor")):
        full = os.path.join(OVL, d)
        for f in sorted(os.listdir(full)) if os.path.isdir(full) else []:
            p = os.path.join(full, f)
            if os.path.isfile(p) and open(p, "rb").read(4) == b"\x7fELF":
                targets.append((p, ns))
    # libraries a vendor process dlopen()s by name (e.g. the Cedar decoder plugins)
    for rel in os.environ.get("LINK_CHECK_LIBS", "").split():
        targets.append((os.path.join(OVL, rel), "vendor"))
    bad = 0
    for p, ns in targets:
        order, origins, problems, missing = check(p, ns)
        rel = os.path.relpath(p, OVL)
        status = "OK " if not problems and not missing else "BAD"
        bad += status == "BAD"
        print(f"[{status}] {ns:6s} {rel}: {len(order)} libs in load group, "
              f"{sum(len(Lib.get(x).undef) for x in order if x.startswith(OVL))} imports checked")
        for m in problems + missing[:15]:
            print("        -", m)
        if len(missing) > 15:
            print(f"        ... {len(missing) - 15} more")
    print(f"\n{len(targets)} entry points, {bad} with problems")
    return 1 if bad else 0


sys.exit(main())
