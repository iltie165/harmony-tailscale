#!/usr/bin/env bash
# Read-only prerequisite checks. Never pull images or install/hydrate packages.
set -euo pipefail
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
missing=0
for tool in bash git make python3 docker; do
  if command -v "$tool" >/dev/null 2>&1; then
    echo "PASS: $tool"
  else
    echo "MISSING: $tool"
    missing=1
  fi
done
if command -v docker >/dev/null 2>&1; then
  for image in "${HARMONY_GO_IMAGE:-harmonyos-go:1.24}" "${HARMONY_DEV_IMAGE:-harmonyos-dev:24.04}"; do
    if docker image inspect "$image" >/dev/null 2>&1; then
      echo "PASS: existing image $image"
    else
      echo "MISSING: existing image $image (or Docker daemon unavailable)"
      missing=1
    fi
  done
fi
module_cache=${HARMONY_GOMODCACHE:-$project_root/.cache/gomod}
if [[ "$module_cache" != /* ]]; then
  echo 'MISSING: HARMONY_GOMODCACHE must be an absolute path'
  missing=1
elif [[ -f "$module_cache/tailscale.com@v1.86.2/go.mod" ]]; then
  echo 'PASS: cached tailscale.com@v1.86.2 (complete graph verified by make test)'
else
  echo 'MISSING: pre-hydrated module cache with tailscale.com@v1.86.2'
  missing=1
fi
for tool in openssl jq; do
  if command -v "$tool" >/dev/null 2>&1; then
    echo "PASS: optional signing tool $tool"
  else
    echo "NOTE: optional signing tool $tool not found"
  fi
done
echo 'Toolchain presence is not compilation or device evidence; see docs/building.md.'
exit "$missing"
