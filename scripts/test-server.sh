#!/usr/bin/env bash
# Offline verification of production Go/C ABI/NAPI using existing images only.
set -euo pipefail
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
module_cache=${HARMONY_GOMODCACHE:-"$project_root/.cache/gomod"}
[[ -f "$module_cache/tailscale.com@v1.86.2/go.mod" ]] || { echo "Missing pre-hydrated module cache: $module_cache" >&2; exit 1; }
mkdir -p "$project_root/.cache/gobuild-host" "$project_root/dist/tests"
docker run --rm --pull never --network none \
  -v "$project_root:/workspace" \
  -v "$module_cache:/gomodcache:ro" \
  -v "$project_root/.cache/gobuild-host:/gocache" \
  -e GOMODCACHE=/gomodcache -e GOCACHE=/gocache -e GOPROXY=off -e GOSUMDB=off \
  -e GOOS=linux -e GOARCH=amd64 -e CGO_ENABLED=1 -e CC=gcc -e CXX=g++ \
  -w /workspace "${HARMONY_GO_IMAGE:-harmonyos-go:1.24}" bash -lc '
    set -euo pipefail
    export PATH=/opt/harmony/command-line-tools/tool/node/bin:$PATH
    [[ -z "$(gofmt -l core/*.go)" ]] || { echo "Go formatting required" >&2; exit 1; }
    go mod verify
    go vet -mod=readonly ./core
    if ! HARMONY_CONTRACT_DIR=/workspace/dist/tests/contracts go test -mod=readonly -race -count=1 -timeout=90s -json -coverprofile=dist/tests/go.cover ./core >dist/tests/go.jsonl; then
      cat dist/tests/go.jsonl
      exit 1
    fi
    go tool cover -func=dist/tests/go.cover | tee dist/tests/go-coverage.txt
    python3 scripts/check-coverage.py
    go build -mod=readonly -buildvcs=false -trimpath -buildmode=c-shared \
      -ldflags "-X tailscale.com/version.shortStamp=1.86.2" \
      -o dist/tests/libtailscale_host.so ./core
    cp dist/tests/libtailscale_host.h dist/tests/libtailscale_ohos.h
    HARMONY_HOST_LIBRARY=/workspace/dist/tests/libtailscale_host.so python3 tests/abi_test.py
    node_include=/opt/harmony/command-line-tools/tool/node/include/node
    for variant in real mock; do
      sources=(entry/src/main/cpp/napi_init.cpp entry/src/main/cpp/vpn_descriptor.cpp tests/host/sdk_shim.cpp)
      link=()
      if [[ "$variant" == real ]]; then
        link=(-L/workspace/dist/tests -ltailscale_host -Wl,-rpath,\$ORIGIN)
      else
        sources+=(tests/host/mock_core.cpp)
      fi
      g++ -std=c++20 -shared -fPIC -Wall -Wextra -Werror -Wno-deprecated-declarations \
        -Itests/host/include -I"$node_include" -Idist/tests \
        "${sources[@]}" "${link[@]}" -o "dist/tests/tailscale-$variant.node"
      HARMONY_HOST_NAPI="/workspace/dist/tests/tailscale-$variant.node" \
        HARMONY_NAPI_REAL="$([[ "$variant" == real ]] && echo 1 || echo 0)" \
        HARMONY_TEST_HILOG_PATH="/workspace/dist/tests/hilog-$variant.txt" \
        node --test tests/napi.test.cjs
    done
  '
"$project_root/scripts/test-ui.sh"
echo 'Offline server checks: PASS'
