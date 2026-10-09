#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
image=${HARMONY_GO_IMAGE:-harmonyos-go:1.24}
proxy=${HARMONY_PROXY_URL:-http://127.0.0.1:7890}
all_proxy=${HARMONY_ALL_PROXY_URL:-socks5://127.0.0.1:7890}
module_cache="$project_root/.cache/gomod"
build_cache="$project_root/.cache/gobuild"
dist_dir="$project_root/dist"

if [[ ! -f "$module_cache/tailscale.com@v1.86.2/go.mod" ]]; then
  echo "missing cached module: tailscale.com@v1.86.2" >&2
  exit 1
fi

mkdir -p "$build_cache" "$dist_dir"

docker run --rm --network host \
  -v "$project_root:/workspace" \
  -v "$module_cache:/gomodcache:ro" \
  -v "$build_cache:/gocache" \
  -e GOMODCACHE=/gomodcache \
  -e GOCACHE=/gocache \
  -e HTTP_PROXY="$proxy" \
  -e HTTPS_PROXY="$proxy" \
  -e ALL_PROXY="$all_proxy" \
  -e GOPROXY=off \
  -e GOSUMDB=off \
  -e GOOS=openharmony \
  -e GOARCH=arm64 \
  -e CGO_ENABLED=1 \
  -e CC=/opt/harmony/command-line-tools/sdk/default/openharmony/native/llvm/bin/aarch64-unknown-linux-ohos-clang \
  -e CXX=/opt/harmony/command-line-tools/sdk/default/openharmony/native/llvm/bin/aarch64-unknown-linux-ohos-clang++ \
  -w /workspace \
  "$image" \
  go build -buildvcs=false -trimpath -mod=readonly -buildmode=c-shared \
    -ldflags '-s -w -X tailscale.com/version.shortStamp=1.86.2 -X tailscale.com/version.longStamp=1.86.2 -X tailscale.com/version.gitCommitStamp=d72494bac7a2fb6b6a01715cfc5bcc903dbd7594' \
    -o /workspace/dist/libtailscale_ohos.so ./core

"$project_root/scripts/verify.sh"
