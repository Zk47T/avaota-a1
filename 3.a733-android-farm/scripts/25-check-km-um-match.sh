#!/usr/bin/env bash
# Static check that the self-built kernel driver (KM) will accept the Android
# userspace blobs (UM) at connect time: same DDK version, same build, and no
# "strict" build-option bit differs (rules from services/server/common/srvcore.c).
set -euo pipefail
source "$(dirname "$0")/env.sh"
W=$FARM/out/rogue_km-android
U=$FARM/src/android-gpu/img-rgx/bxm/arm64/lib64/libsrv_um.so
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# KM side: evaluate RGX_BUILD_OPTIONS_KM from the generated build config
cat > "$T/k.c" <<'C'
#include <stdio.h>
#include "config_kernel.h"
#include "rgx_options.h"
#include "pvrversion.h"
int main(void){printf("%lu %lu %lu %lu %u %u %u\n",
 (unsigned long)RGX_BUILD_OPTIONS_KM,(unsigned long)RGX_BUILD_OPTIONS_MASK_KM,
 (unsigned long)KM_OPTIONS_STRICT,(unsigned long)UM_OPTIONS_STRICT,
 PVRVERSION_MAJ,PVRVERSION_MIN,PVRVERSION_BUILD);return 0;}
C
gcc -I "$W"/binary_sunxi_android_release -I "$W/include/rogue" -I "$W/include" "$T/k.c" -o "$T/k"
read -r KOPT KMASK KSTRICT USTRICT KMAJ KMIN KBUILD < <("$T/k")

# UM side: libsrv_um passes (options, version, build) as immediates in w2/w3/w4
# right before the SRVCORE connect bridge call. Find the movk that loads the
# DDK major (0x18 = 24) into w3 and read the three registers around it.
"${CROSS_COMPILE}objdump" -d --no-show-raw-insn "$U" > "$T/u.dis"
python3 -I - "$T/u.dis" "$KOPT" "$KMASK" "$KSTRICT" "$USTRICT" "$KMAJ" "$KMIN" "$KBUILD" <<'PY'
import re,sys
lines=open(sys.argv[1]).read().splitlines()
kopt,kmask,kstrict,ustrict,kmaj,kmin,kbuild=map(int,sys.argv[2:])
hit=[i for i,l in enumerate(lines) if re.search(r"movk\s+w3, #0x%x, lsl #16"%kmaj,l)]
if not hit: sys.exit("UM: connect constants not found (pattern changed?)")
i=hit[0]; reg={}
for l in lines[i-12:i+3]:
    m=re.search(r"\b(mov|movk)\s+w([234]), #0x([0-9a-f]+)(, lsl #16)?",l)
    if not m: continue
    r=int(m.group(2)); v=int(m.group(3),16)
    reg[r]= (reg.get(r,0)&0xffff)|(v<<16) if m.group(4) else v
uopt,uver,ubuild=reg.get(2),reg.get(3),reg.get(4)
km=kopt&kmask; um=uopt&kmask; mis=km^um
print(f"KM : DDK {kmaj}.{kmin}@{kbuild}  options(masked)=0x{km:08x}")
print(f"UM : DDK {uver>>16}.{uver&0xffff}@{ubuild}  options(masked)=0x{um:08x}  (raw 0x{uopt:08x})")
ok=True
if (uver>>16,uver&0xffff)!=(kmaj,kmin): print("FAIL: DDK version differs (hard error)"); ok=False
if ubuild!=kbuild: print("WARN: DDK build differs (warning only, unless PVRSRV_STRICT_COMPAT_CHECK)")
if um&mis&ustrict: print(f"FAIL: client strict bits 0x{um&mis&ustrict:08x}"); ok=False
if km&mis&kstrict: print(f"FAIL: server strict bits 0x{km&mis&kstrict:08x}"); ok=False
print("RESULT:", "PASS - connect handshake will be accepted" if ok else "FAIL")
sys.exit(0 if ok else 1)
PY
