# Source this: the redroid base image for each Android version the overlays support
# (README section 18). `redroid_base 12|13|17` sets
#   BASE    the image the overlay is built FROM
#   ROOT    an extracted copy of its system/vendor files (out/cache), for the link checks
#   API     the Android API level Mesa is built for (31 / 33 / 35; NDK r29 stops at 35,
#           and an API 35 build runs on Android 17 = API 37)
#   SUFFIX  output-name suffix: "" for 13 (the original kit), -12 / -17 otherwise
redroid_base() {
  case "$1" in
    12) BASE=redroid/redroid:12.0.0_64only-latest@sha256:a6c464bbedcf1dcb67dbf91f329fbb19bee5b50631f0ca6bda6ed7c41b0e64e2
        ROOT=$FARM/out/cache/redroid-12.0.0_64only-latest/root; API=31; SUFFIX=-12 ;;
    13) BASE=redroid/redroid:13.0.0_64only-240527
        ROOT=$FARM/out/cache/redroid-13.0.0_64only-240527/root; API=33; SUFFIX= ;;
    17) # our own build: 5.redroid-self-build/4.rk3588-a17 (Nredroid 17.0.0, Mesa 26.1.4); not on Docker Hub.
        # 20261030 = first-stage init + the container fixes (guide 3.2 fixes 6-9). 20261014 and
        # 20261029 cannot boot; 20261029b has no audio
        BASE=aic/redroid-rk3588:17.0.0-panthor-20261030
        ROOT=$FARM/out/cache/redroid-17.0.0-nredroid-20261030/root; API=35; SUFFIX=-17 ;;
    *) echo "REDROID: 12, 13 or 17"; return 1 ;;
  esac
  # 13's copy comes from 26-check-blobs-vs-redroid.sh (registry download). 12 and 17 are
  # exported from docker; 17 has to be loaded from its tar first.
  if [ "$1" != 13 ] && [ ! -d "$ROOT/system/etc" ]; then
    if ! docker image inspect "$BASE" >/dev/null 2>&1; then
      [ "$1" = 17 ] && { echo "load it first: zstd -dc aic-redroid-rk3588-17.0.0-panthor-20261030.tar.zst | docker load"; return 1; }
      docker pull --platform linux/arm64 "$BASE"
    fi
    mkdir -p "$ROOT"
    local cid; cid=$(docker create --platform linux/arm64 "$BASE")
    docker export "$cid" | tar -x -C "$ROOT" --wildcards 'system/apex/*' 'system/lib64/*' 'system/etc/*' \
      'system/build.prop' 'vendor/*' 2>/dev/null || true
    docker rm "$cid" >/dev/null
  fi
}
