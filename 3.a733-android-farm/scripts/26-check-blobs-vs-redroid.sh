#!/usr/bin/env bash
# Static link check of the PowerVR blobs against the real redroid 13 arm64
# image, using Android's linker-namespace rules (sphal / vendor, VNDK-SP, LLNDK).
# Downloads the image layer once (~640 MB) via the Docker registry API, no docker needed.
set -euo pipefail
source "$(dirname "$0")/env.sh"
REPO=redroid/redroid TAG=${REDROID_TAG:-13.0.0_64only-240527}
CACHE=$FARM/out/cache/redroid-$TAG; ROOT=$CACHE/root
if [ ! -d "$ROOT/system/apex/com.android.vndk.current" ]; then
  mkdir -p "$CACHE"
  TOK=$(curl -s "https://auth.docker.io/token?service=registry.docker.io&scope=repository:$REPO:pull" | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
  H=(-H "Authorization: Bearer $TOK")
  IDX=$(curl -s "${H[@]}" -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json" "https://registry-1.docker.io/v2/$REPO/manifests/$TAG")
  DIG=$(echo "$IDX" | python3 -c 'import sys,json; print([m["digest"] for m in json.load(sys.stdin)["manifests"] if m["platform"]["architecture"]=="arm64"][0])')
  LAYERS=$(curl -s "${H[@]}" -H "Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json" "https://registry-1.docker.io/v2/$REPO/manifests/$DIG" | python3 -c 'import sys,json; [print(l["digest"]) for l in json.load(sys.stdin)["layers"]]')
  mkdir -p "$ROOT"
  for L in $LAYERS; do
    echo "downloading layer $L"
    curl -sL "${H[@]}" "https://registry-1.docker.io/v2/$REPO/blobs/$L" -o "$CACHE/layer.tgz"
    tar -xzf "$CACHE/layer.tgz" -C "$ROOT" --wildcards 'system/apex/com.android.vndk.current/*' \
        'system/apex/com.android.runtime/*' 'system/lib64/*' 'vendor/*' 2>/dev/null || true
    rm -f "$CACHE/layer.tgz"
  done
fi
[ -d "$FARM/out/redroid-pvr/vendor" ] || "$FARM/scripts/30-make-redroid-pvr-context.sh"
cd / && python3 -E "$FARM/scripts/redroid_link_check.py" "$ROOT" "$FARM/out/redroid-pvr/vendor"
