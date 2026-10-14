"""Execute production signing orchestration with fake external tools, no credentials."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile

PROJECT = Path(__file__).resolve().parents[1]


class SigningTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        for name in ['scripts', 'entry', 'AppScope', 'fake-bin', 'private', 'out']:
            (self.root / name).mkdir()
        for name in ['version.py', 'sign-hap.sh']:
            shutil.copyfile(PROJECT / 'scripts' / name, self.root / 'scripts' / name)
        (self.root / 'VERSION').write_text('0.1.0-alpha.1\n')
        app = {'versionName': '0.1.0-alpha.1', 'versionCode': 3004002, 'bundleName': 'com.ezoo.tailscaleprobe'}
        (self.root / 'AppScope/app.json5').write_text(json.dumps({'app': app}))
        for name in ['oh-package.json5', 'entry/oh-package.json5']:
            (self.root / name).write_text(json.dumps({'version': app['versionName']}))
        self.unsigned = self.root / 'out/unsigned.hap'
        with zipfile.ZipFile(self.unsigned, 'w') as archive:
            archive.writestr('module.json', json.dumps({'app': app}))
        self.signed = self.root / 'out/signed.hap'
        for name in ['debug.p12', 'tailscala-hos-debug.p7b']:
            (self.root / 'private' / name).write_text('test fixture, not a credential')
        (self.root / 'private/lch-phone.cer').write_text('-----BEGIN CERTIFICATE-----\nTEST\n-----BEGIN CERTIFICATE-----\nTEST\n')
        self.env = os.environ.copy()
        self.env.update(PATH=str(self.root / 'fake-bin') + os.pathsep + os.environ['PATH'],
                        HARMONY_SIGNING_DIR=str(self.root / 'private'),
                        HARMONY_KEYSTORE_PASSWORD='test-fixture-not-a-credential',
                        FAKE_DOCKER_MARKER=str(self.root / 'docker-called'),
                        FAKE_FINAL_PATH=str(self.signed))
        for name in ['HARMONY_KEYSTORE_FILE', 'HARMONY_APP_CERT_FILE', 'HARMONY_PROFILE_FILE']:
            self.env.pop(name, None)
        self.tool('openssl', "import sys,json\nfrom pathlib import Path\nPath(sys.argv[sys.argv.index('-out')+1]).write_text(json.dumps({'bundle-info':{'bundle-name':'com.ezoo.tailscaleprobe'}}))\n")
        self.tool('jq', "print('com.ezoo.tailscaleprobe')\n")
        self.tool('docker', """import sys,os,shutil
from pathlib import Path
args=sys.argv[1:]; mounts={}
for index,arg in enumerate(args[:-1]):
    if arg=='-v':
        parts=args[index+1].split(':');mounts[parts[1]]=parts[0]
Path(os.environ['FAKE_DOCKER_MARKER']).write_text('fake signing invoked')
shutil.copyfile(mounts['/input/app-unsigned.hap'],Path(mounts['/work'])/'signed.hap')
""")
        self.tool('verify-hap.sh', """import os,sys
from pathlib import Path
if os.environ.get('FAKE_VERIFY_FAIL')=='1':sys.exit(1)
if os.environ.get('FAKE_CREATE_RACE')=='1':Path(os.environ['FAKE_FINAL_PATH']).write_bytes(b'concurrent-existing-artifact')
""", self.root / 'scripts')

    def tool(self, name, source, directory=None):
        path = (directory or self.root / 'fake-bin') / name
        path.write_text('#!' + sys.executable + '\n' + source)
        path.chmod(0o755)

    def run_signer(self):
        return subprocess.run(['bash', str(self.root / 'scripts/sign-hap.sh'), str(self.unsigned), str(self.signed)],
                              env=self.env, capture_output=True, text=True, timeout=20)

    def test_existing_artifact_is_refused_before_tools_or_credentials(self):
        self.signed.write_bytes(b'keep-existing')
        self.env.pop('HARMONY_KEYSTORE_PASSWORD')
        result = self.run_signer()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('refusing to overwrite', result.stderr)
        self.assertEqual(self.signed.read_bytes(), b'keep-existing')
        self.assertFalse((self.root / 'docker-called').exists())

    def test_failed_payload_verification_never_publishes_final_file(self):
        self.env['FAKE_VERIFY_FAIL'] = '1'
        result = self.run_signer()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.signed.exists())
        self.assertFalse(list(self.signed.parent.glob('.sign-hap.*')))

    def test_concurrent_destination_is_not_overwritten(self):
        self.env['FAKE_CREATE_RACE'] = '1'
        result = self.run_signer()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.signed.read_bytes(), b'concurrent-existing-artifact')

    def test_verified_bytes_are_published_and_temporary_files_removed(self):
        result = self.run_signer()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.signed.read_bytes(), self.unsigned.read_bytes())
        self.assertFalse(list(self.signed.parent.glob('.sign-hap.*')))


if __name__ == '__main__':
    unittest.main()
