"""Execute the actual Linux c-shared library, not a modeled copy of the ABI."""
import concurrent.futures
import ctypes
import json
import os
import unittest


class ABI(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lib = ctypes.CDLL(os.environ['HARMONY_HOST_LIBRARY'])
        for name in ['version', 'go_version', 'start', 'status', 'login', 'logout',
                     'online_peers', 'close', 'diagnostics', 'logs']:
            fn = getattr(cls.lib, 'tailscale_ohos_' + name)
            fn.restype = ctypes.c_void_p  # c_char_p would lose the owned pointer.
            fn.argtypes = {'start': [ctypes.c_char_p, ctypes.c_char_p],
                          'online_peers': [ctypes.c_char_p],
                          'diagnostics': [ctypes.c_char_p]}.get(name, [])
        cls.lib.tailscale_ohos_string_free.argtypes = [ctypes.c_void_p]
        cls.lib.tailscale_ohos_string_free.restype = None

    def call(self, name, *args):
        ptr = getattr(self.lib, 'tailscale_ohos_' + name)(*args)
        self.assertIsNotNone(ptr)
        try:
            return ctypes.string_at(ptr).decode('utf-8')
        finally:
            self.lib.tailscale_ohos_string_free(ptr)

    def test_version(self):
        self.assertEqual(self.lib.tailscale_ohos_abi_version(), 3)
        self.assertEqual(self.lib.tailscale_ohos_core_probe(), 1)
        self.assertEqual(self.call('version'), '1.86.2')
        self.assertTrue(self.call('go_version').startswith('go1.24.'))

    def test_invalid_inputs_are_json_errors(self):
        for directory, host in [(None, None), (b'', b'host'), (b'relative', b'host'),
                                (b'/tmp', b''), (b'/tmp', b'bad_host'),
                                (b'/tmp', '中文'.encode())]:
            with self.subTest(directory=directory, host=host):
                result = json.loads(self.call('start', directory, host))
                self.assertIs(result['ok'], False)
                self.assertEqual(result['operation'], 'start')
                self.assertTrue(result['error'])

    def test_idle_calls_are_structured_and_close_is_idempotent(self):
        for name in ['status', 'login', 'logout']:
            result = json.loads(self.call(name))
            self.assertIs(result['ok'], False)
            self.assertEqual(result['operation'], name)
        for _ in range(3):
            self.assertIs(json.loads(self.call('close'))['ok'], True)
        self.assertIs(json.loads(self.call('online_peers', None))['ok'], False)
        result = json.loads(self.call('online_peers', b'group:dev'))
        self.assertEqual(result['peers'], [])
        self.assertEqual(result['filterKind'], 'acl-group')

    def test_log_tail_reaches_last_record_and_buffers_are_independent(self):
        self.call('start', b'relative', b'older-record')
        older = self.call('logs')
        self.call('start', b'/tmp', 'newest_中文'.encode())
        current = self.call('logs')
        self.assertIn('unsupported character', current)
        self.assertGreater(len(current), len(older))
        self.assertNotEqual(older, current)

    def test_concurrent_string_ownership(self):
        def read(_):
            for _ in range(40):
                self.call('version')
                self.call('go_version')
                json.loads(self.call('status'))
                self.call('logs')
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            list(pool.map(read, range(8)))


if __name__ == '__main__':
    unittest.main(verbosity=2)
