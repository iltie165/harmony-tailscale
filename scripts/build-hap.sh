#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
image=${HARMONY_DEV_IMAGE:-harmonyos-dev:24.04}
build_mode=${HARMONY_BUILD_MODE:-debug}
[[ "$build_mode" == debug || "$build_mode" == release ]] || { echo 'build mode must be debug or release' >&2; exit 1; }
build_network=${HARMONY_BUILD_NETWORK:-none}
proxy=${HARMONY_PROXY_URL:-http://127.0.0.1:7890}
all_proxy=${HARMONY_ALL_PROXY_URL:-socks5://127.0.0.1:7890}
native_lib_dir="$project_root/entry/libs/arm64-v8a"
native_include_dir="$project_root/entry/src/main/cpp/include"
artifact_name=$(python3 "$project_root/scripts/version.py" artifact unsigned)

"$project_root/scripts/build.sh"
docker run --rm --pull never --network none -v "$project_root:/workspace:ro" \
  "${HARMONY_GO_IMAGE:-harmonyos-go:1.24}" go version -m /workspace/dist/libtailscale_ohos.so \
  > "$project_root/dist/go-build-metadata.txt"
python3 "$project_root/scripts/notices.py" --metadata "$project_root/dist/go-build-metadata.txt"

mkdir -p "$native_lib_dir" "$native_include_dir"
cp "$project_root/dist/libtailscale_ohos.so" "$native_lib_dir/libtailscale_ohos.so"
cp "$project_root/dist/libtailscale_ohos.h" "$native_include_dir/libtailscale_ohos.h"

docker run --rm --pull never --network "$build_network" \
  -e DEVECO_SDK_HOME=/opt/harmony/command-line-tools/sdk \
  -e HARMONY_BUILD_MODE="$build_mode" \
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
      -p buildMode="$HARMONY_BUILD_MODE" \
      --no-daemon \
      assembleHap
  '

hap="$project_root/entry/build/default/outputs/default/entry-default-unsigned.hap"
if [[ ! -f "$hap" ]]; then
  echo "Hvigor finished without producing an unsigned HAP" >&2
  exit 1
fi

mkdir -p "$project_root/dist/hap"
HARMONY_EXPECT_BUILD_MODE="$build_mode" "$project_root/scripts/verify-hap.sh" "$hap"
cp "$hap" "$project_root/dist/hap/$artifact_name"
# Retain the unsigned compatibility alias; never overwrite an old signed release.
cp "$hap" "$project_root/dist/hap/tailscale-probe-unsigned.hap"
echo "HAP: $project_root/dist/hap/$artifact_name"
