#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
image=${HARMONY_DEV_IMAGE:-harmonyos-dev:24.04}
proxy=${HARMONY_PROXY_URL:-http://127.0.0.1:7890}
all_proxy=${HARMONY_ALL_PROXY_URL:-socks5://127.0.0.1:7890}
hap=${1:-"$project_root/dist/hap/tailscale-probe-unsigned.hap"}

[[ -f "$hap" ]] || { echo "missing HAP: $hap" >&2; exit 1; }

archive=$(unzip -Z1 "$hap")
for entry in \
  libs/arm64-v8a/libtailscale_napi.so \
  libs/arm64-v8a/libtailscale_ohos.so \
  ets/modules.abc \
  module.json; do
  grep -Fxq "$entry" <<<"$archive" || { echo "missing HAP entry: $entry" >&2; exit 1; }
done

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
unzip -p "$hap" libs/arm64-v8a/libtailscale_napi.so >"$work_dir/libtailscale_napi.so"
unzip -p "$hap" libs/arm64-v8a/libtailscale_ohos.so >"$work_dir/libtailscale_ohos.so"

docker run --rm --network host \
  -v "$work_dir:/verify:ro" \
  -e HTTP_PROXY="$proxy" \
  -e HTTPS_PROXY="$proxy" \
  -e ALL_PROXY="$all_proxy" \
  "$image" bash -lc '
    set -euo pipefail
    for library in /verify/*.so; do
      readelf -h "$library" | grep -Eq "Machine:[[:space:]]+AArch64"
    done
    readelf -d /verify/libtailscale_napi.so | grep -q "libtailscale_ohos.so"
    readelf -Ws /verify/libtailscale_ohos.so | grep -Eq "[[:space:]]tailscale_ohos_start$"
    if readelf -rW /verify/libtailscale_ohos.so | grep -q R_AARCH64_TLS_TPREL64; then
      echo "forbidden TLS relocation in packaged Go library" >&2
      exit 1
    fi
  '

echo "HAP native payload verification: PASS"
