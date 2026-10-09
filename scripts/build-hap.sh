#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
image=${HARMONY_DEV_IMAGE:-harmonyos-dev:24.04}
proxy=${HARMONY_PROXY_URL:-http://127.0.0.1:7890}
all_proxy=${HARMONY_ALL_PROXY_URL:-socks5://127.0.0.1:7890}
native_lib_dir="$project_root/entry/libs/arm64-v8a"
native_include_dir="$project_root/entry/src/main/cpp/include"

"$project_root/scripts/build.sh"

mkdir -p "$native_lib_dir" "$native_include_dir"
cp "$project_root/dist/libtailscale_ohos.so" "$native_lib_dir/libtailscale_ohos.so"
cp "$project_root/dist/libtailscale_ohos.h" "$native_include_dir/libtailscale_ohos.h"

docker run --rm --network host \
  -e DEVECO_SDK_HOME=/opt/harmony/command-line-tools/sdk \
  -e HTTP_PROXY="$proxy" \
  -e HTTPS_PROXY="$proxy" \
  -e ALL_PROXY="$all_proxy" \
  -v "$project_root:/workspace" \
  -w /workspace \
  "$image" bash -lc '
    set -euo pipefail
    mkdir -p /tmp/hvigor-node/@ohos /tmp/ohos-sdk
    ln -s /opt/harmony/command-line-tools/hvigor/hvigor-ohos-plugin /tmp/hvigor-node/@ohos/hvigor-ohos-plugin
    ln -s /opt/harmony/command-line-tools/hvigor/hvigor /tmp/hvigor-node/@ohos/hvigor
    ln -s /opt/harmony/command-line-tools/sdk/default/openharmony /tmp/ohos-sdk/26.0.0
    for package in hvigor-common hvigor-logger; do
      source=$(find /opt/harmony/command-line-tools/hvigor -type d -path "*/node_modules/@ohos/$package" | head -1)
      [[ -n "$source" ]] && ln -s "$source" "/tmp/hvigor-node/@ohos/$package"
    done
    export PATH=/opt/harmony/command-line-tools/tool/node/bin:$PATH
    export NODE_PATH=/tmp/hvigor-node:/opt/harmony/command-line-tools/hvigor/hvigor/node_modules:/opt/harmony/command-line-tools/hvigor/hvigor-ohos-plugin/node_modules
    node /opt/harmony/command-line-tools/hvigor/hvigor/bin/hvigor.js \
      --mode module \
      -p product=default \
      -p module=entry@default \
      -p buildMode=debug \
      --no-daemon \
      assembleHap
  '

hap=$(find "$project_root/entry/build" -type f -name '*-unsigned.hap' | sort | head -1)
if [[ -z "$hap" ]]; then
  echo "Hvigor finished without producing an unsigned HAP" >&2
  exit 1
fi

mkdir -p "$project_root/dist/hap"
cp "$hap" "$project_root/dist/hap/tailscale-probe-unsigned.hap"
"$project_root/scripts/verify-hap.sh" "$project_root/dist/hap/tailscale-probe-unsigned.hap"
echo "HAP: $project_root/dist/hap/tailscale-probe-unsigned.hap"
