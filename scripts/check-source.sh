#!/usr/bin/env bash
set -euo pipefail
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$project_root"
for script in scripts/*.sh; do bash -n "$script"; done
git diff --check
python3 - <<'PY'
import ast
from pathlib import Path
for path in Path('tests').glob('*.py'):
    ast.parse(path.read_text(), filename=str(path))
# No dependency installation, HDC, secrets, public network, or signing is part
# of the offline regression gate. Source and fixtures are UTF-8/LF.
for root in ('core', 'tests', 'entry/src/main/ets'):
    for path in Path(root).rglob('*'):
        if path.suffix not in {'.go', '.cjs', '.py', '.cpp', '.h', '.ets'}:
            continue
        text = path.read_text()
        if '\r' in text or not text.endswith('\n'):
            raise SystemExit(f'Expected UTF-8 LF and final newline: {path}')
print('Source hygiene: PASS')
PY
