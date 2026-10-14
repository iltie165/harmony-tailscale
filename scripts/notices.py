#!/usr/bin/env python3
"""Collect notices for linked Go modules from an existing verified cache, offline."""

import argparse
import hashlib
import json
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RAW = Path('entry/src/main/resources/rawfile/open-source-notices.txt')
INVENTORY = Path('third_party/linked-modules.json')


def cache_escape(value):
    return ''.join('!' + char.lower() if char.isupper() else char for char in value)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def linked_modules(text):
    return [{'module': fields[1], 'version': fields[2], 'goSum': fields[3]}
            for line in text.splitlines() if (fields := line.split()) and fields[0] == 'dep']


def legal_file(path):
    name = path.name.lower()
    if path.suffix.lower() in {'.go', '.py', '.cpp', '.rs', '.sh'}:
        return False
    return name.startswith(('license', 'copying', 'notice', 'patents', 'copyright', 'authors')) or (
        path.parent.name.lower() in {'licenses', 'license'} and path.suffix.lower() in {'.txt', '.md'})


def generate(metadata_path, cache):
    modules = linked_modules(metadata_path.read_text())
    if not modules or not any(m['module'] == 'tailscale.com' and m['version'] == 'v1.86.2' for m in modules):
        raise ValueError('Missing pinned Tailscale in actual Go binary metadata')
    sections = ['harmony-tailscale — Open source notices\n\n'
                'This bundle preserves supplied license/notice texts for linked Go modules, Go runtime and SDK LLVM.\n'
                'It is not a completed legal audit. Subdirectory terms remain applicable. Artwork rights are separate.\n']
    for label, name in [('Project MIT license', 'LICENSE'), ('Go runtime supplied notices', 'third_party/go/NOTICE'),
                        ('SDK LLVM supplied notices (includes toolchain components)', 'third_party/llvm/NOTICE')]:
        sections.append('\n' + '=' * 72 + '\n' + label + '\n' + (ROOT / name).read_text())
    for module in modules:
        directory = cache / (cache_escape(module['module']) + '@' + cache_escape(module['version']))
        if not directory.is_dir():
            raise ValueError('Missing cached module: ' + module['module'])
        files = sorted(p for p in directory.rglob('*') if p.is_file() and legal_file(p))
        if not files:
            raise ValueError('No supplied license/notice file found: ' + module['module'])
        module['notices'] = []
        for path in files:
            raw = path.read_bytes()
            content = raw.decode('utf-8')
            relative = path.relative_to(directory).as_posix()
            module['notices'].append({'path': relative, 'sha256': digest(raw)})
            sections.append('\n' + '=' * 72 + '\n' + module['module'] + ' ' + module['version'] + '\n' + relative + '\n\n' + content)
    data = ('\n'.join(sections).rstrip() + '\n').encode()
    inventory = {'schemaVersion': 1, 'scope': 'Actual linked Go module metadata; supplied notices, not a completed license audit',
                 'upstream': 'tailscale.com v1.86.2', 'modules': modules, 'bundleSha256': digest(data)}
    (ROOT / 'THIRD_PARTY_NOTICES.txt').write_bytes(data)
    (ROOT / RAW).parent.mkdir(parents=True, exist_ok=True)
    (ROOT / RAW).write_bytes(data)
    (ROOT / INVENTORY).write_text(json.dumps(inventory, ensure_ascii=False, indent=2) + '\n')
    print(f'Collected notices for {len(modules)} linked Go modules; {len(data)} bytes')


def check():
    data = (ROOT / 'THIRD_PARTY_NOTICES.txt').read_bytes()
    inventory = json.loads((ROOT / INVENTORY).read_text())
    if digest(data) != inventory['bundleSha256'] or data != (ROOT / RAW).read_bytes():
        raise ValueError('Notice inventory/bundle/packaged raw resource mismatch')
    print(f'Notice bundle integrity: PASS ({len(inventory["modules"])} linked Go modules)')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--metadata', type=Path)
    parser.add_argument('--cache', type=Path, default=Path(os.environ.get('HARMONY_GOMODCACHE', ROOT / '.cache/gomod')))
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    try:
        if args.check:
            check()
        elif args.metadata:
            generate(args.metadata, args.cache)
        else:
            parser.error('Choose --check or --metadata')
    except (ValueError, OSError, KeyError) as error:
        parser.exit(1, f'Notice collection failed: {error}\n')
