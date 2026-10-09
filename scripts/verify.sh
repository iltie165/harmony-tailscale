#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
image=${HARMONY_GO_IMAGE:-harmonyos-go:1.24}
proxy=${HARMONY_PROXY_URL:-http://127.0.0.1:7890}
all_proxy=${HARMONY_ALL_PROXY_URL:-socks5://127.0.0.1:7890}
library="$project_root/dist/libtailscale_ohos.so"
header="$project_root/dist/libtailscale_ohos.h"

[[ -f "$library" ]] || { echo "missing $library" >&2; exit 1; }
[[ -f "$header" ]] || { echo "missing $header" >&2; exit 1; }

docker run --rm --network host \
  -v "$project_root:/workspace:ro" \
  -e HTTP_PROXY="$proxy" \
  -e HTTPS_PROXY="$proxy" \
  -e ALL_PROXY="$all_proxy" \
  -w /workspace \
  "$image" bash -lc '
    set -euo pipefail
    library=/workspace/dist/libtailscale_ohos.so
    header=/workspace/dist/libtailscale_ohos.h

    file "$library"
    readelf -h "$library" | tee /tmp/elf-header.txt
    grep -Eq "Machine:[[:space:]]+AArch64" /tmp/elf-header.txt

    readelf -Ws "$library" | tee /tmp/elf-symbols.txt >/dev/null
    for symbol in \
      tailscale_ohos_abi_version \
      tailscale_ohos_version \
      tailscale_ohos_go_version \
      tailscale_ohos_core_probe \
      tailscale_ohos_start \
      tailscale_ohos_status \
      tailscale_ohos_close \
      tailscale_ohos_diagnostics \
      tailscale_ohos_logs \
      tailscale_ohos_string_free; do
      grep -Eq "[[:space:]]${symbol}$" /tmp/elf-symbols.txt
    done

    readelf -rW "$library" | tee /tmp/elf-relocations.txt >/dev/null
    if grep -q "R_AARCH64_TLS_TPREL64" /tmp/elf-relocations.txt; then
      echo "forbidden TLS relocation: R_AARCH64_TLS_TPREL64" >&2
      exit 1
    fi

    echo "TLSDESC relocations: $(grep -c R_AARCH64_TLSDESC /tmp/elf-relocations.txt || true)"
    strings "$library" | grep -F "tailscale.com/tsnet.(*Server).Start" >/dev/null

    cxx=/opt/harmony/command-line-tools/sdk/default/openharmony/native/llvm/bin/aarch64-unknown-linux-ohos-clang++
    "$cxx" -shared -fPIC -Wl,-z,defs \
      -I/workspace/dist \
      /workspace/tests/native_smoke.cpp \
      -L/workspace/dist -ltailscale_ohos \
      -o /tmp/libtailscale_ohos_native_smoke.so
    readelf -h /tmp/libtailscale_ohos_native_smoke.so | grep -Eq "Machine:[[:space:]]+AArch64"
    readelf -d /tmp/libtailscale_ohos_native_smoke.so | grep -q "libtailscale_ohos.so"
    echo "Native C++ smoke link: PASS"

    echo "Dynamic dependencies:"
    readelf -d "$library" | grep NEEDED || true
    echo "Go module metadata:"
    go version -m "$library"
    echo "Generated header exports:"
    grep -E "tailscale_ohos_" "$header"
  '
