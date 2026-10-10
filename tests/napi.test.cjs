'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const native = require(process.env.HARMONY_HOST_NAPI);
const real = process.env.HARMONY_NAPI_REAL === '1';
const parse = async (value) => JSON.parse(await value);

test('production NAPI module registers exactly the TypeScript contract', () => {
  const declarations = fs.readFileSync(path.join(__dirname, '../entry/src/main/cpp/types/libtailscale_napi/index.d.ts'), 'utf8');
  const expected = [...declarations.matchAll(/export const (\w+):/g)].map((m) => m[1]).sort();
  assert.deepEqual(Object.getOwnPropertyNames(native).sort(), expected);
  const version = JSON.parse(native.getVersion());
  assert.equal(version.abiVersion, 3);
  assert.equal(version.tailscaleVersion, '1.86.2');
  assert.equal(version.coreProbe, true);
});
test('wrong argument counts and types are rejected before entering C ABI', () => {
  for (const args of [[], ['/tmp'], [1, 'host'], ['/tmp', null], ['/tmp', 'a\0b'], ['/tmp\0elsewhere', 'host']]) {
    assert.throws(() => native.start(...args), TypeError);
  }
  for (const fn of ['onlinePeers', 'diagnostics']) {
    assert.throws(() => native[fn](), TypeError);
    assert.throws(() => native[fn](42), TypeError);
  }
});
test('async methods return real Promises and the proper operation JSON', async () => {
  for (const [name, args, operation] of [
    ['start', ['relative', 'host'], 'start'], ['getStatus', [], 'status'],
    ['login', [], 'login'], ['logout', [], 'logout'],
    ['onlinePeers', ['group:dev'], 'onlinePeers'], ['close', [], 'close'],
    ...(!real ? [['diagnostics', ['/private'], 'diagnostics']] : [])
  ]) {
    const promise = native[name](...args);
    assert.ok(promise instanceof Promise);
    const result = await parse(promise);
    assert.equal(result.operation, operation);
    assert.equal(typeof result.ok, 'boolean');
    if (real && operation !== 'close') assert.equal(result.ok, false);
  }
});
test('NAPI SDK allocation/queue failures throw and subsequent work recovers', async () => {
  for (const stage of ['promise', 'work', 'queue']) {
    process.env.HARMONY_TEST_NAPI_FAULT = stage;
    try { assert.throws(() => native.getStatus(), /napi_.*failed/); }
    finally { delete process.env.HARMONY_TEST_NAPI_FAULT; }
    assert.equal((await parse(native.getStatus())).operation, 'status');
  }
});
test('owned strings survive repeated conversion and async calls', async () => {
  for (let i = 0; i < 80; i++) {
    assert.equal(typeof native.getLogs(), 'string');
    await Promise.all([native.getStatus(), native.close(), native.onlinePeers('')]);
  }
});
if (!real) {
  test('null/empty Go result rejects the Promise instead of returning fake success', async () => {
    for (const filter of ['null-result', 'empty-result']) {
      await assert.rejects(native.onlinePeers(filter), /empty result/);
    }
  });
  test('blocking Go work runs off the Node event loop', async () => {
    const pending = native.start('/private', 'slow');
    let finished = false;
    pending.then(() => { finished = true; });
    await new Promise((resolve) => setTimeout(resolve, 10));
    assert.equal(finished, false);
    assert.equal((await parse(pending)).ok, true);
  });
  test('login URL is returned to caller but not written to HiLog; log tail is atomic', async () => {
    const capture = process.env.HARMONY_TEST_HILOG_PATH;
    fs.writeFileSync(capture, '');
    const login = await parse(native.login());
    assert.match(login.authUrl, /private-native-token/);
    native.getLogs();
    const logs = fs.readFileSync(capture, 'utf8');
    assert.ok(!logs.includes('private-native-token'));
    assert.ok(logs.includes('newest control error retained'));
    assert.ok(logs.includes('中文'));
    assert.ok(!logs.includes('x'.repeat(2500)));
    for (const record of logs.split('Go log tail (newest retained):\n').slice(1)) {
      assert.ok(Buffer.byteLength(record.split('Async ')[0]) < 3000);
    }
  });
}

if (!real) {
  test('oversized last log line retains its newest suffix with valid UTF-8', () => {
    const capture = process.env.HARMONY_TEST_HILOG_PATH;
    fs.writeFileSync(capture, '');
    process.env.HARMONY_TEST_LONG_LOG = '1';
    try { native.getLogs(); }
    finally { delete process.env.HARMONY_TEST_LONG_LOG; }
    const bytes = fs.readFileSync(capture);
    const text = new TextDecoder('utf-8', { fatal: true }).decode(bytes);
    assert.ok(text.includes('newest-marker'));
    assert.ok(text.includes('中'));
    assert.ok(bytes.length < 3000);
  });
}
