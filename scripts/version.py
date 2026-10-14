#!/usr/bin/env python3
"""Manage project SemVer and verify HarmonyOS/package/HAP metadata offline."""

import argparse
import json
import os
from pathlib import Path
import re
import stat
import tempfile
import zipfile


ROOT = Path(__file__).resolve().parent.parent
LEGACY_VERSION_CODE = 3004001
MAX_VERSION_CODE = 2147483647
VERSION_PATTERN = re.compile(
    r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)'
    r'(?:-(alpha|beta|rc)\.([1-9][0-9]*))?'
)
METADATA = ('AppScope/app.json5', 'oh-package.json5', 'entry/oh-package.json5')


def precedence(version: str) -> tuple:
    match = VERSION_PATTERN.fullmatch(version)
    if not match or len(version.encode()) > 127:
        raise ValueError('Expected X.Y.Z or X.Y.Z-{alpha,beta,rc}.N; no v prefix, leading zeros or build metadata')
    major, minor, patch, channel, sequence = match.groups()
    stage = {'alpha': 0, 'beta': 1, 'rc': 2, None: 3}[channel]
    return int(major), int(minor), int(patch), stage, int(sequence or 0)


def read_metadata(root: Path) -> dict:
    # Maintained .json5 metadata uses the valid JSON subset, without comments.
    return {name: json.loads((root / name).read_text()) for name in METADATA}


def check(root: Path = ROOT, hap: Path | None = None) -> tuple[str, int]:
    version = (root / 'VERSION').read_text().strip()
    precedence(version)
    metadata = read_metadata(root)
    app = metadata['AppScope/app.json5']['app']
    code = app['versionCode']
    if type(code) is not int or not LEGACY_VERSION_CODE < code <= MAX_VERSION_CODE:
        raise ValueError('versionCode must be an integer above the legacy upgrade floor and within the SDK range')
    if app['versionName'] != version:
        raise ValueError('AppScope versionName differs from VERSION')
    for name in METADATA[1:]:
        if metadata[name]['version'] != version:
            raise ValueError(f'{name} version differs from VERSION')
    if hap is not None:
        with zipfile.ZipFile(hap) as archive:
            packaged = json.loads(archive.read('module.json'))['app']
        if (packaged.get('versionName'), packaged.get('versionCode'), packaged.get('bundleName')) != (
                version, code, app['bundleName']):
            raise ValueError('HAP version/name/code/bundle differs from current source metadata')
    return version, code


def set_version(version: str, code: int, root: Path = ROOT) -> None:
    current, previous_code = check(root)
    if precedence(version) <= precedence(current):
        raise ValueError('New project version must be greater than the current version')
    if type(code) is not int or not previous_code < code <= MAX_VERSION_CODE:
        raise ValueError('New versionCode must increase and stay within the SDK range')
    metadata = read_metadata(root)
    metadata['AppScope/app.json5']['app'].update(versionName=version, versionCode=code)
    for name in METADATA[1:]:
        metadata[name]['version'] = version
    replacements = {name: (json.dumps(data, ensure_ascii=False, indent=2) + '\n').encode()
                    for name, data in metadata.items()}
    replacements['VERSION'] = (version + '\n').encode()
    # Prepare original/new bytes before mutation. Individual replacements are
    # atomic; catchable failures restore already-replaced files without new writes.
    # A killed process can still interrupt a multi-file transaction: check fails
    # closed on drift rather than pretending the whole filesystem is atomic.
    with tempfile.TemporaryDirectory(prefix='.version-stage-', dir=root) as staging:
        stage = Path(staging)
        originals = {}
        updates = {}
        for index, (name, content) in enumerate(replacements.items()):
            path = root / name
            originals[name] = stage / f'{index}.old'
            updates[name] = stage / f'{index}.new'
            originals[name].write_bytes(path.read_bytes())
            updates[name].write_bytes(content)
            mode = stat.S_IMODE(path.stat().st_mode)
            os.chmod(originals[name], mode)
            os.chmod(updates[name], mode)
        changed = []
        try:
            for name in replacements:
                os.replace(updates[name], root / name)
                changed.append(name)
        except OSError:
            rollback_errors = []
            for name in reversed(changed):
                try:
                    os.replace(originals[name], root / name)
                except OSError:
                    rollback_errors.append(name)
            if rollback_errors:
                raise ValueError('Version update and rollback failed; restore metadata from Git before building') from None
            raise


def artifact(kind: str, root: Path = ROOT) -> str:
    version, _ = check(root)
    if kind not in ('unsigned', 'signed'):
        raise ValueError('Artifact kind must be unsigned or signed')
    return f'harmony-tailscale-{version}-arm64-{kind}.hap'


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('show')
    verify = commands.add_parser('check')
    verify.add_argument('--hap', type=Path)
    update = commands.add_parser('set')
    update.add_argument('version')
    update.add_argument('--code', type=int, required=True)
    filename = commands.add_parser('artifact')
    filename.add_argument('kind', choices=('unsigned', 'signed'))
    args = parser.parse_args()
    try:
        if args.command == 'set':
            set_version(args.version, args.code)
        if args.command == 'artifact':
            print(artifact(args.kind))
        else:
            version, code = check(hap=getattr(args, 'hap', None))
            print(f'{version} (versionCode {code})')
    except (ValueError, KeyError, OSError, zipfile.BadZipFile) as error:
        parser.exit(1, f'Version check failed: {error}\n')


if __name__ == '__main__':
    main()
