#!/usr/bin/env python3
"""Prepare a truthful, local unsigned release-candidate manifest, not publication."""

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('project_version', ROOT / 'scripts/version.py')
versioning = importlib.util.module_from_spec(spec)
spec.loader.exec_module(versioning)


def inspect_artifact(path, root=ROOT):
    version, code = versioning.check(root, path)
    if path.name != versioning.artifact('unsigned', root):
        raise ValueError('Candidate must use the canonical unsigned artifact name')
    with zipfile.ZipFile(path) as archive:
        app = json.loads(archive.read('module.json'))['app']
    if app.get('debug') is not False:
        raise ValueError('Candidate must be built in release mode, not debug')
    return {'name': path.name, 'size': path.stat().st_size,
            'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
            'version': version, 'versionCode': code, 'bundleName': app['bundleName'],
            'buildMode': 'release', 'signed': False, 'signatureVerified': False}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('hap', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    try:
        artifact = inspect_artifact(args.hap)
        commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
        dirty = bool(subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT, text=True).strip())
        source = subprocess.check_output(['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard'], cwd=ROOT).decode().split('\0')
        source_digest = hashlib.sha256()
        for name in sorted(set(filter(None, source))):
            path = ROOT / name
            if path.is_file():
                source_digest.update(name.encode() + b'\0' + path.read_bytes() + b'\0')
        manifest = {'schemaVersion': 1, 'status': 'candidate_not_published', 'sourceCommit': commit,
                    'sourceDirty': dirty, 'sourceTreeSha256': source_digest.hexdigest(), 'artifact': artifact,
                    'target': {'arch': 'arm64', 'minimumAPI': 24, 'targetAPI': 26},
                    'noticesSha256': hashlib.sha256((ROOT / 'THIRD_PARTY_NOTICES.txt').read_bytes()).hexdigest(),
                    'acceptance': {'phoneVerified': False, 'publicSigningChannelVerified': False,
                                   'artworkRedistributionConfirmed': False}}
        output = args.output or args.hap.with_name('harmony-tailscale-' + artifact['version'] + '-candidate.json')
        output.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
        args.hap.with_name(args.hap.name + '.sha256').write_text(artifact['sha256'] + '  ' + args.hap.name + '\n')
        print('Unsigned candidate manifest: ' + str(output))
    except (ValueError, OSError, KeyError, zipfile.BadZipFile) as error:
        parser.exit(1, f'Candidate check failed: {error}\n')
