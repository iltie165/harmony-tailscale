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
    napi_dynamic=$(readelf -d /verify/libtailscale_napi.so)
    grep -Fq "Shared library: [libtailscale_ohos.so]" <<<"$napi_dynamic"
    if grep -Eq "Shared library: \[[^]]*/" <<<"$napi_dynamic"; then
      echo "packaged NAPI library contains an absolute DT_NEEDED path" >&2
      exit 1
    fi
    if grep -Eq "\((RPATH|RUNPATH)\)" <<<"$napi_dynamic"; then
      echo "packaged NAPI library contains a build-time RPATH/RUNPATH" >&2
      exit 1
    fi
    napi_symbols=$(readelf -Ws /verify/libtailscale_napi.so)
    grep -q "napi_module_register" <<<"$napi_symbols"
    grep -q "napi_define_properties" <<<"$napi_symbols"
    napi_strings=$(strings -a /verify/libtailscale_napi.so)
    for property in getVersion getStatus getLogs start diagnostics close tailscale_napi; do
      grep -Fxq "$property" <<<"$napi_strings"
    done
    readelf -Ws /verify/libtailscale_ohos.so | grep -Eq "[[:space:]]tailscale_ohos_start$"
    if readelf -rW /verify/libtailscale_ohos.so | grep -q R_AARCH64_TLS_TPREL64; then
      echo "forbidden TLS relocation in packaged Go library" >&2
      exit 1
    fi
  '

echo "HAP native payload verification: PASS"
