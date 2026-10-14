"""Version management at metadata and packaged-HAP boundaries; no SDK needed."""

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import zipfile


spec = importlib.util.spec_from_file_location('project_version', Path(__file__).resolve().parents[1] / 'scripts/version.py')
versioning = importlib.util.module_from_spec(spec)
spec.loader.exec_module(versioning)


class VersionTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / 'AppScope').mkdir()
        (self.root / 'entry').mkdir()
        (self.root / 'VERSION').write_text('0.1.0-alpha.1\n')
        self.app = {'versionName': '0.1.0-alpha.1', 'versionCode': 3004002,
                    'bundleName': 'com.ezoo.tailscaleprobe', 'vendor': 'unchanged'}
        (self.root / 'AppScope/app.json5').write_text(json.dumps({'app': self.app}))
        for name in versioning.METADATA[1:]:
            (self.root / name).write_text(json.dumps({'version': '0.1.0-alpha.1', 'dependencies': {}}))

    def test_precedence_channels_and_numeric_sequence(self):
        versions = ['0.1.0-alpha.2', '0.1.0-alpha.10', '0.1.0-beta.1',
                    '0.1.0-rc.1', '0.1.0', '0.1.1-alpha.1', '0.2.0', '1.0.0']
        self.assertEqual(versions, sorted(reversed(versions), key=versioning.precedence))

    def test_noncanonical_versions_are_rejected(self):
        for value in ['v0.1.0', '0.01.0', '0.1', '0.1.0-alpha', '0.1.0-alpha.01',
                      '0.1.0-alpha.0', '0.1.0-dev.1', '0.1.0+build.1', '0.1.0\n']:
            with self.subTest(value=value), self.assertRaises(ValueError):
                versioning.precedence(value)

    def test_set_synchronizes_metadata_and_preserves_unrelated_fields(self):
        versioning.set_version('0.1.0-alpha.2', 3004003, self.root)
        self.assertEqual(versioning.check(self.root), ('0.1.0-alpha.2', 3004003))
        metadata = versioning.read_metadata(self.root)
        self.assertEqual(metadata['AppScope/app.json5']['app']['vendor'], 'unchanged')
        self.assertEqual(metadata['entry/oh-package.json5']['dependencies'], {})

    def test_downgrade_or_reused_code_does_not_edit_files(self):
        before = {p: p.read_bytes() for p in self.root.rglob('*') if p.is_file()}
        for value, code in [('0.1.0-alpha.1', 3004003), ('0.0.9', 3004003),
                            ('0.1.0-beta.1', 3004002), ('0.1.0-beta.1', 2147483648)]:
            with self.subTest(value=value, code=code), self.assertRaises(ValueError):
                versioning.set_version(value, code, self.root)
        self.assertEqual(before, {p: p.read_bytes() for p in before})

    def test_metadata_drift_is_rejected_before_edit(self):
        path = self.root / 'entry/oh-package.json5'
        path.write_text(json.dumps({'version': '2.0.0'}))
        with self.assertRaises(ValueError):
            versioning.set_version('0.1.0-beta.1', 3004003, self.root)
        self.assertEqual((self.root / 'VERSION').read_text(), '0.1.0-alpha.1\n')

    def test_legacy_code_floor_boolean_and_sdk_range(self):
        for code in [1, 3004001, True, 2147483648]:
            with self.subTest(code=code):
                (self.root / 'AppScope/app.json5').write_text(json.dumps({'app': {**self.app, 'versionCode': code}}))
                with self.assertRaises(ValueError):
                    versioning.check(self.root)

    def test_hap_contract_rejects_stale_version_code_and_bundle(self):
        path = self.root / 'app.hap'
        for change in [{}, {'versionName': '3.4.1'}, {'versionCode': 3004001},
                       {'bundleName': 'com.example.another'}]:
            with self.subTest(change=change):
                with zipfile.ZipFile(path, 'w') as archive:
                    archive.writestr('module.json', json.dumps({'app': {**self.app, **change}}))
                if change:
                    with self.assertRaises(ValueError):
                        versioning.check(self.root, path)
                else:
                    self.assertEqual(versioning.check(self.root, path), ('0.1.0-alpha.1', 3004002))

    def test_artifacts_follow_version_and_architecture(self):
        self.assertEqual(versioning.artifact('signed', self.root), 'harmony-tailscale-0.1.0-alpha.1-arm64-signed.hap')
        versioning.set_version('0.1.0-rc.1', 3004003, self.root)
        self.assertEqual(versioning.artifact('unsigned', self.root), 'harmony-tailscale-0.1.0-rc.1-arm64-unsigned.hap')


if __name__ == '__main__':
    unittest.main()
