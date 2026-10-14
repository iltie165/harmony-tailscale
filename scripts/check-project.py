#!/usr/bin/env python3
"""SDK-free project hygiene and repository-relative Markdown link checks."""

from pathlib import Path
import re
import subprocess
from urllib.parse import unquote, urlsplit


ROOT = Path(__file__).resolve().parent.parent


def check() -> None:
    failures = []
    documents = sorted(ROOT.glob('*.md')) + sorted((ROOT / 'docs').rglob('*.md'))
    documents += sorted((ROOT / 'third_party').rglob('*.md'))
    documents += sorted((ROOT / '.github').rglob('*.md'))
    checked = 0
    for document in documents:
        # Fenced code contains examples, not rendered Markdown links.
        body = re.sub(r'^```[^\n]*\n.*?^```\s*$', '', document.read_text(),
                      flags=re.MULTILINE | re.DOTALL)
        for match in re.finditer(r'!?\[[^\]\n]*\]\(([^\s)]+)(?:\s+"[^"]*")?\)', body):
            link = match.group(1).strip('<>')
            parsed = urlsplit(link)
            if parsed.scheme or parsed.netloc or not parsed.path:
                continue
            target = (document.parent / unquote(parsed.path)).resolve()
            checked += 1
            if not target.is_relative_to(ROOT) or not target.exists():
                failures.append(f'{document.relative_to(ROOT)}: missing/local-escape link {link}')

    required = (
        'README.md', 'LICENSE', 'VERSION', 'CONTRIBUTING.md', 'CHANGELOG.md', 'SECURITY.md', 'SUPPORT.md',
        'THIRD_PARTY.md', 'docs/README.md', 'docs/building.md', 'docs/versioning.md', 'docs/project-readiness.md',
        'docs/releases/README.md', 'docs/archive/README.md',
        '.github/pull_request_template.md', '.github/ISSUE_TEMPLATE/bug_report.yml',
        '.github/ISSUE_TEMPLATE/feature_request.yml', '.github/workflows/source.yml',
        '.github/workflows/check.yml', 'third_party/tailscale/LICENSE',
        'third_party/tailscale/PATENTS',
    )
    for name in required:
        if not (ROOT / name).is_file():
            failures.append(f'Missing maintained project entry: {name}')

    tracked = subprocess.check_output(['git', 'ls-files', '-z'], cwd=ROOT).decode().split('\0')
    private_suffixes = {'.p12', '.pfx', '.pem', '.key', '.cer', '.p7b', '.hap', '.so'}
    for name in filter(None, tracked):
        if Path(name).suffix.lower() in private_suffixes or Path(name).name.startswith('.env'):
            if Path(name).name != '.env.example':
                failures.append(f'Private/generated material tracked by Git: {name}')
        if name.startswith(('dist/', '.cache/', 'entry/build/', 'entry/libs/')):
            failures.append(f'Generated directory tracked by Git: {name}')

    if failures:
        raise SystemExit('\n'.join(failures))
    print(f'Project hygiene: PASS ({len(documents)} Markdown files, {checked} local links)')


if __name__ == '__main__':
    check()
