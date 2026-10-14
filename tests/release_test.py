"""Candidate manifest rejects debug, stale or deceptively named packages."""

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('candidate_manifest', ROOT / 'scripts/release-manifest.py')
manifest = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manifest)


class CandidateTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        for name in ['AppScope', 'entry']:
            (self.root / name).mkdir()
        (self.root / 'VERSION').write_text('0.1.0-alpha.1\n')
        self.app = {'versionName': '0.1.0-alpha.1', 'versionCode': 3004002,
                    'bundleName': 'com.ezoo.tailscaleprobe', 'debug': False}
        (self.root / 'AppScope/app.json5').write_text(json.dumps({'app': self.app}))
        for name in ['oh-package.json5', 'entry/oh-package.json5']:
            (self.root / name).write_text(json.dumps({'version': self.app['versionName']}))
        self.hap = self.root / 'harmony-tailscale-0.1.0-alpha.1-arm64-unsigned.hap'

    def package(self, app):
        with zipfile.ZipFile(self.hap, 'w') as archive:
            archive.writestr('module.json', json.dumps({'app': app}))

    def test_real_release_metadata_is_reported_as_unsigned(self):
        self.package(self.app)
        result = manifest.inspect_artifact(self.hap, self.root)
        self.assertEqual(result['buildMode'], 'release')
        self.assertEqual(result['versionCode'], 3004002)
        self.assertFalse(result['signed'])
        self.assertFalse(result['signatureVerified'])
        self.assertEqual(len(result['sha256']), 64)

    def test_debug_or_stale_hap_is_rejected(self):
        for change in [{'debug': True}, {'versionName': '3.4.1'}, {'versionCode': 3004001}]:
            with self.subTest(change=change):
                self.package({**self.app, **change})
                with self.assertRaises(ValueError):
                    manifest.inspect_artifact(self.hap, self.root)

    def test_unsigned_bytes_cannot_be_labeled_signed(self):
        self.package(self.app)
        other = self.hap.with_name('harmony-tailscale-0.1.0-alpha.1-arm64-signed.hap')
        self.hap.rename(other)
        with self.assertRaises(ValueError):
            manifest.inspect_artifact(other, self.root)


if __name__ == '__main__':
    unittest.main()
