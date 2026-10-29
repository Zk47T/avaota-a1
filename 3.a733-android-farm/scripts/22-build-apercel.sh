#!/usr/bin/env bash
# Build the open PowerVR host driver "apercel" (CheezeCS fork: upstream
# drm/imagination + 30 backported fixes, proven on an Orange Pi Zero 3W with
# Imagination fw 1.1) against the host kernel from 10-build-host-kernel.sh,
# plus the three DRM helper modules it imports. README section 16.10.
# Needs: ./scripts/00-fetch-sources.sh kernel apercel, and a built kernel tree.
# Output: out/apercel/{apercel,gpu-sched,drm_exec,drm_shmem_helper}.ko + SHA256SUMS
set -euo pipefail
source "$(dirname "$0")/env.sh"
[ -f "$KOUT/Module.symvers" ] || { echo "build the kernel first (10-build-host-kernel.sh)"; exit 1; }
[ -d "$FARM/src/apercel/driver" ] || { echo "fetch it first: ./scripts/00-fetch-sources.sh apercel"; exit 1; }

W=$FARM/out/apercel-build
O=$FARM/out/apercel
rm -rf "$W" "$O"; mkdir -p "$W/sched" "$W/drm" "$O"   # never build inside src/

# DRM_SCHED, DRM_EXEC and DRM_GEM_SHMEM_HELPER are prompt-less tristates in the
# Orange Pi tree and are off in our config, so build them as external modules
# from the tree's own sources. Same code and module names as the Route L build.
cp "$KSRC"/drivers/gpu/drm/scheduler/*.[ch] "$KSRC"/drivers/gpu/drm/scheduler/Makefile "$W/sched/"
cp "$KSRC"/drivers/gpu/drm/drm_exec.c "$KSRC"/drivers/gpu/drm/drm_gem_shmem_helper.c "$W/drm/"
cat > "$W/drm/Kbuild" <<'EOF'
obj-m += drm_exec.o drm_shmem_helper.o
drm_shmem_helper-y := drm_gem_shmem_helper.o
EOF
make -C "$KOUT" M="$W/sched" CONFIG_DRM_SCHED=m -j"$JOBS" modules
make -C "$KOUT" M="$W/drm" -j"$JOBS" modules
cat "$W/sched/Module.symvers" "$W/drm/Module.symvers" > "$W/helpers.symvers"

# apercel itself. DRM_SYMVERS gives modpost the helpers' exports.
cp -a "$FARM/src/apercel/driver" "$W/apercel"
make -C "$KOUT" M="$W/apercel" DRM_SYMVERS="$W/helpers.symvers" -j"$JOBS" modules 2>&1 \
  | tee "$W/apercel-build.log" | grep -E "error|warning: |WARNING|\.ko" || true
[ -f "$W/apercel/apercel.ko" ] || { echo "FAILED, see $W/apercel-build.log"; exit 1; }

cp "$W/apercel/apercel.ko" "$W/sched/gpu-sched.ko" "$W/drm/drm_exec.ko" "$W/drm/drm_shmem_helper.ko" "$O/"
for k in "$O"/*.ko; do "${CROSS_COMPILE}strip" --strip-debug "$k"; done

# A module may not export a symbol that vmlinux or another module already exports.
nm_exports() { "${CROSS_COMPILE}nm" "$1" | awk '$3 ~ /^__ksymtab_/ {sub(/^__ksymtab_/, "", $3); print $3}'; }
for k in "$O"/*.ko; do nm_exports "$k"; done | sort > "$W/exports.txt"
awk '{print $2}' "$KOUT/Module.symvers" | sort > "$W/vmlinux-exports.txt"
DUP=$( (sort "$W/exports.txt" | uniq -d; comm -12 "$W/exports.txt" "$W/vmlinux-exports.txt") | sort -u)
[ -z "$DUP" ] || { echo "duplicate exports, the load would fail:"; echo "$DUP"; exit 1; }

(cd "$O" && sha256sum ./*.ko > SHA256SUMS)
# Read .modinfo directly: the host's modinfo shows its own built-in module info
# when a name matches (drm_shmem_helper is built into many distro kernels).
mi() { "${CROSS_COMPILE}readelf" -p .modinfo "$1" | sed -n "s/^ *\[ *[0-9a-f]*\] *$2=//p"; }
for k in "$O"/*.ko; do
  printf '%-22s %s | depends: %s\n' "$(basename "$k")" "$(mi "$k" vermagic)" "$(mi "$k" depends)"
done
mi "$O/apercel.ko" alias | grep '^of:' || true
mi "$O/apercel.ko" parm || true
echo "apercel source: CheezeCS/apercel $(git -C "$FARM/src/apercel" rev-parse --short=12 HEAD)"
