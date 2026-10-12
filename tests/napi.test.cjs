'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const native = require(process.env.HARMONY_HOST_NAPI);
const real = process.env.HARMONY_NAPI_REAL === '1';
const parse = async (value) => JSON.parse(await value);

test('VPN descriptor inspection validates arguments and preserves borrowed FD ownership', async () => {
  for (const args of [[], ['1'], [-1], [1.5], [Infinity], [NaN], [2147483648], [1, 2]]) {
    assert.throws(() => native.inspectVpnDescriptor(...args), TypeError);
  }
  const invalid = await parse(native.inspectVpnDescriptor(2147483647));
  assert.equal(invalid.ok, false);
  assert.equal(invalid.descriptorValid, false);
  const fd = fs.openSync('/dev/null', 'r+');
  try {
    const before = fs.readdirSync('/proc/self/fd').length;
    for (let i = 0; i < 40; i++) {
      const pending = native.inspectVpnDescriptor(fd);
      assert.ok(pending instanceof Promise);
      const result = await parse(pending);
      assert.equal(result.ok, true);
      assert.equal(result.readWriteDescriptor, true);
      assert.equal(result.tunnelConnected, false);
      assert.ok(fs.fstatSync(fd).isCharacterDevice());
    }
    assert.equal(fs.readdirSync('/proc/self/fd').length, before);
  } finally { fs.closeSync(fd); }
  const readOnly = fs.openSync('/dev/null', 'r');
  try { assert.equal((await parse(native.inspectVpnDescriptor(readOnly))).ok, false); }
  finally { fs.closeSync(readOnly); }
  const regular = fs.openSync(__filename, 'r+');
  try { assert.equal((await parse(native.inspectVpnDescriptor(regular))).ok, false); }
  finally { fs.closeSync(regular); }
});

test('native descriptor failures expose access, type and errno without changing descriptor ownership', async () => {
  const invalid = await parse(native.inspectVpnDescriptor(2147483647));
  assert.equal(invalid.checkStage, 'duplicate');
  assert.equal(invalid.errno, 9); // EBADF on the real Linux host.
  for (const [file, mode, access, type, stage] of [
    ['/dev/null', 'r', 'read-only', 'character', 'accessMode'],
    ['/dev/null', 'w', 'write-only', 'character', 'accessMode'],
    [__filename, 'r+', 'read-write', 'regular', 'fileType']
  ]) {
    const fd = fs.openSync(file, mode);
    try {
      const result = await parse(native.inspectVpnDescriptor(fd));
      assert.equal(result.ok, false);
      assert.equal(result.descriptorValid, true);
      assert.equal(result.readWriteDescriptor, mode === 'r+');
      assert.equal(result.accessMode, access);
      assert.equal(result.fileType, type);
      assert.equal(result.checkStage, stage);
      assert.equal(result.flagsErrno, 0);
      assert.equal(result.statErrno, 0);
      assert.equal(result.duplicateClosed, true);
      assert.equal(result.closeErrno, 0);
      assert.equal(typeof result.flags, 'number');
      assert.equal(result.fileMode, fs.fstatSync(fd).mode);
      assert.equal(result.tunnelConnected, false);
      assert.ok(result.error);
      fs.fstatSync(fd); // Native inspection did not close the caller's FD.
    } finally { fs.closeSync(fd); }
  }
});

test('sandbox metadata denial is an explicit limitation, not FD invalidity or packet verification', async () => {
  const fd = fs.openSync('/dev/null', 'r+');
  try {
    for (const [fault, expectedErrno, tolerated] of [
      ['EACCES', 13, true], ['EPERM', 1, true], ['EBADF', 9, false], ['EIO', 5, false]
    ]) {
      process.env.HARMONY_TEST_DESCRIPTOR_FAULT = fault;
      let result;
      try { result = await parse(native.inspectVpnDescriptor(fd)); }
      finally { delete process.env.HARMONY_TEST_DESCRIPTOR_FAULT; }
      assert.equal(result.ok, tolerated);
      assert.equal(result.descriptorValid, true);
      assert.equal(result.readWriteDescriptor, true);
      assert.equal(result.metadataAvailable, false);
      assert.equal(result.statErrno, expectedErrno);
      assert.equal(result.fileType, 'unknown');
      assert.equal(result.packetIOVerified, false);
      assert.equal(result.tunnelConnected, false);
      assert.equal(result.duplicateClosed, true);
      assert.equal(result.checkStage, tolerated ? 'complete' : 'stat');
      assert.equal(result.error === '', tolerated);
      if (tolerated) assert.match(result.warning, /metadata.*denied.*unverified/);
      else assert.equal(result.warning, '');
      fs.fstatSync(fd); // The host wrapper cannot change ownership or Node's fstat.
    }
    const readOnly = fs.openSync('/dev/null', 'r');
    try {
      process.env.HARMONY_TEST_DESCRIPTOR_FAULT = 'EACCES';
      const result = await parse(native.inspectVpnDescriptor(readOnly));
      assert.equal(result.ok, false);
      assert.equal(result.readWriteDescriptor, false);
      assert.equal(result.checkStage, 'accessMode');
    } finally { delete process.env.HARMONY_TEST_DESCRIPTOR_FAULT; fs.closeSync(readOnly); }
  } finally { fs.closeSync(fd); }
});

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
  for (const args of [[], [1], ['{}', 'extra'], ['a\0b']]) {
    assert.throws(() => native.configurePlatform(...args), TypeError);
  }
  for (const args of [[], ['/tmp', 'host', '100.64.1.1'], ['/tmp', 'host', '100.64.1.1', -1],
    ['/tmp', 'host', '100.64.1.1', 1.5], ['/tmp', 'host', '100.64.1.1', Infinity],
    ['/tmp', 'a\0b', '100.64.1.1', 1], ['/tmp', 'host', 42, 1], ['/tmp', 'host', '100.64.1.1', 1, 'extra']]) {
    assert.throws(() => native.startVpn(...args), TypeError);
  }
  for (const args of [[], ['/tmp'], [1, 'host'], ['/tmp', null], ['/tmp', 'a\0b'], ['/tmp\0elsewhere', 'host']]) {
    for (const method of ['start','startService','connectService']) assert.throws(() => native[method](...args), TypeError);
  }
  for (const fn of ['onlinePeers', 'diagnostics']) {
    assert.throws(() => native[fn](), TypeError);
    assert.throws(() => native[fn](42), TypeError);
  }
});
test('platform metadata uses the asynchronous owned-string C ABI', async () => {
  const result = await parse(native.configurePlatform('{"os":"openharmony","osVersion":"6.1.1.120","deviceModel":"test-phone"}'));
  assert.equal(result.ok, true); assert.equal(result.operation, 'configurePlatform');
  if (real) {
    assert.equal((await parse(native.configurePlatform('{"os":"linux"}'))).ok, false);
  }
});
test('VPN NAPI startup and independent status use the real async ABI', async () => {
  const result = await parse(native.startVpn('relative', 'host', '100.64.1.1', 2147483647));
  assert.equal(result.operation, 'startVpn');
  assert.equal(result.ok, !real);
  const status = await parse(native.getVpnStatus());
  assert.equal(status.connected, false);
  assert.equal(status.state, 'disconnected');
  assert.equal(status.txPackets, 0);
});
test('async methods return real Promises and the proper operation JSON', async () => {
  for (const [name, args, operation] of [
    ['startService', ['relative', 'host'], 'startService'],
    ['connectService', ['relative', 'host'], 'connectService'],
    ['detachVpn', [], 'detachVpn'], ['disconnectClient', [], 'disconnectClient'],
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
    if (real && operation !== 'close' && operation !== 'disconnectClient') assert.equal(result.ok, false);
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
