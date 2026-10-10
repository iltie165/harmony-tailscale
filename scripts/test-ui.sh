#!/usr/bin/env bash
set -euo pipefail
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
docker run --rm --network none -v "$project_root:/workspace:ro" -w /workspace \
  "${HARMONY_DEV_IMAGE:-harmonyos-dev:24.04}" bash -lc '
    export PATH=/opt/harmony/command-line-tools/tool/node/bin:$PATH
    export TYPESCRIPT_MODULE=/opt/harmony/command-line-tools/codelinter/node_modules/typescript/lib/typescript.js
    node --test tests/ui.test.cjs
  '
