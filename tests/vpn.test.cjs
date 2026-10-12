'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');
const ts = require(process.env.TYPESCRIPT_MODULE);
const directory = path.join(__dirname, '../entry/src/main/ets/vpn');
function compile(name, dependencies = {}) {
  const output = ts.transpileModule(fs.readFileSync(path.join(directory, name + '.ets'), 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
  }).outputText;
  const mod = new Module(path.join(__dirname, name + '.cjs'), module);
  mod.filename = path.join(__dirname, name + '.cjs');
  mod.require = (id) => Object.hasOwn(dependencies, id) ? dependencies[id] : require(id);
  mod._compile(output, mod.filename);
  return mod.exports;
}
const model = compile('VpnProbeModel');
const client = compile('VpnProbeClient', { './VpnProbeModel': model });
const sessionModel = compile('VpnSessionModel');
const inspected = JSON.stringify({ ok: true, descriptorValid: true, readWriteDescriptor: true });
function port(overrides = {}) {
  const calls = [];
  const value = {
    create: async () => { calls.push('create'); return 17; },
    protectProcessNet: async () => { calls.push('protect'); },
    inspect: async (fd) => { calls.push(['inspect', fd]); return inspected; },
    close: (fd) => { calls.push(['close', fd]); },
    destroy: async () => { calls.push('destroy'); },
    ...overrides
  };
  return { value, calls };
}
function success(id = '123-456') {
  return Object.assign(new model.VpnProbeReport(), {
    requestId: id, ok: true, stage: 'complete', created: true, descriptorValid: true,
    readWriteDescriptor: true, processProtected: true, descriptorClosed: true, destroyed: true,
    descriptorInspection: inspected
  });
}
test('capability probe preserves order, closes once, destroys once and never claims connectivity', async () => {
  const p = port();
  const report = await new model.VpnProbeController().run(p.value, '123-456');
  assert.deepEqual(p.calls, ['create', 'protect', ['inspect', 17], ['close', 17], 'destroy']);
  assert.deepEqual(report, success());
  assert.equal(model.readVpnProbe(JSON.stringify(report), '123-456').tunnelConnected, false);
});
test('a denied create never closes an unowned FD or destroys an unrelated VPN', async () => {
  const p = port({ create: async () => { throw new Error('user denied 2203001'); } });
  const report = await new model.VpnProbeController().run(p.value, '1');
  assert.equal(report.ok, false);
  assert.match(report.error, /user denied 2203001/);
  assert.deepEqual(p.calls, []);
});
test('a resolved create with invalid FD still destroys the acquired VPN', async () => {
  const p = port({ create: async () => -1 });
  const report = await new model.VpnProbeController().run(p.value, '1');
  assert.match(report.error, /invalid descriptor/);
  assert.equal(report.destroyed, true);
  assert.equal(report.descriptorClosed, false);
  assert.deepEqual(p.calls, ['destroy']);
});
test('network-protection failure closes the descriptor and tears down the connection', async () => {
  const p = port({ protectProcessNet: async () => { throw new Error('API unavailable'); } });
  const report = await new model.VpnProbeController().run(p.value, '1');
  assert.equal(report.ok, false);
  assert.match(report.error, /protectProcessNet.*API unavailable/);
  assert.equal(report.descriptorClosed, true);
  assert.equal(report.destroyed, true);
  assert.ok(!p.calls.some((x) => Array.isArray(x) && x[0] === 'inspect'));
});
test('inspection failure and malformed responses do not escape cleanup', async () => {
  for (const raw of ['not JSON', 'null', '{}', '{"ok":true,"descriptorValid":true,"readWriteDescriptor":false}']) {
    const p = port({ inspect: async () => raw });
    const report = await new model.VpnProbeController().run(p.value, '1');
    assert.equal(report.ok, false);
    assert.equal(report.descriptorClosed, true);
    assert.equal(report.destroyed, true);
  }
});

test('a failed native candidate check retains valid FD measurements and all raw diagnostics', async () => {
  const raw = JSON.stringify({ ok: false, descriptorValid: true, readWriteDescriptor: true,
    regularFile: true, accessMode: 'read-write', checkStage: 'fileType', flags: 2,
    error: 'regular-file VPN compatibility unverified' });
  const p = port({ inspect: async () => raw });
  const report = await new model.VpnProbeController().run(p.value, '1');
  assert.equal(report.ok, false);
  assert.equal(report.descriptorValid, true);
  assert.equal(report.readWriteDescriptor, true);
  assert.equal(report.descriptorInspection, raw);
  assert.match(report.error, /regular-file VPN compatibility unverified/);
  assert.equal(report.descriptorClosed, true);
  assert.equal(report.destroyed, true);
  assert.equal(model.readVpnProbe(JSON.stringify(report), '1').ok, false);
});

test('invalid native measurements cannot turn candidate failure into success', async () => {
  const p = port({ inspect: async () => JSON.stringify({ ok: false, descriptorValid: 'yes', readWriteDescriptor: true }) });
  const report = await new model.VpnProbeController().run(p.value, '1');
  assert.equal(report.ok, false);
  assert.equal(report.descriptorValid, false);
  assert.match(report.error, /Invalid native descriptor inspection result/);
  assert.equal(report.destroyed, true);
  assert.throws(() => model.readVpnProbe(JSON.stringify({ ...success(), descriptorInspection: {} }), '123-456'));
});

test('metadata-limited capability success preserves the warning and never claims packet transport', async () => {
  const warning = 'Descriptor metadata query denied by sandbox; packet I/O remains unverified';
  const raw = JSON.stringify({ ok: true, descriptorValid: true, readWriteDescriptor: true,
    metadataAvailable: false, statErrno: 13, packetIOVerified: false, warning });
  const p = port({ inspect: async () => raw });
  const report = await new model.VpnProbeController().run(p.value, '1');
  assert.equal(report.ok, true);
  assert.equal(report.warning, warning);
  assert.equal(report.packetIOVerified, false);
  assert.equal(report.tunnelConnected, false);
  assert.equal(model.readVpnProbe(JSON.stringify(report), '1').warning, warning);
  assert.throws(() => model.readVpnProbe(JSON.stringify({ ...report, packetIOVerified: true }), '1'));
  const falseClaim = await new model.VpnProbeController().run(port({
    inspect: async () => JSON.stringify({ ok: true, descriptorValid: true, readWriteDescriptor: true, packetIOVerified: true })
  }).value, '2');
  assert.equal(falseClaim.ok, false);
  assert.match(falseClaim.error, /Invalid native packet verification claim/);
});
test('close failure still attempts destroy; both failure reasons remain visible', async () => {
  const p = port({ close: () => { throw new Error('close failed'); }, destroy: async () => { throw new Error('destroy failed'); } });
  const report = await new model.VpnProbeController().run(p.value, '1');
  assert.equal(report.ok, false);
  assert.match(report.error, /close failed/);
  assert.match(report.error, /destroy failed/);
  assert.equal(report.destroyed, false);
});
test('extension revocation during create waits for acquisition, then cleans up without inspecting', async () => {
  let release;
  const controller = new model.VpnProbeController();
  const p = port({ create: () => new Promise((resolve) => { release = resolve; }) });
  const pending = controller.run(p.value, '1');
  controller.cancel();
  assert.deepEqual(p.calls, []);
  release(17);
  const report = await pending;
  assert.equal(report.ok, false);
  assert.match(report.error, /cancelled/);
  assert.deepEqual(p.calls, [['close', 17], 'destroy']);
});
test('extension revocation during protection or native inspection preserves FD lifetime', async () => {
  for (const stage of ['protectProcessNet', 'inspect']) {
    let release, entered;
    const started = new Promise((resolve) => { entered = resolve; });
    const p = port({ [stage]: () => { entered(); return new Promise((resolve) => { release = resolve; }); } });
    const controller = new model.VpnProbeController();
    const pending = controller.run(p.value, '1');
    await started;
    controller.cancel();
    assert.ok(!p.calls.some((x) => Array.isArray(x) && x[0] === 'close'));
    release(stage === 'inspect' ? inspected : undefined);
    const report = await pending;
    assert.equal(report.ok, false);
    assert.equal(report.descriptorClosed, true);
    assert.equal(report.destroyed, true);
  }
});
test('concurrent probe requests cannot acquire a second connection', async () => {
  let release;
  const p = port({ create: () => new Promise((resolve) => { release = resolve; }) });
  const controller = new model.VpnProbeController();
  const first = controller.run(p.value, '1');
  await assert.rejects(controller.run(p.value, '2'), /already running/);
  release(17);
  assert.equal((await first).ok, true);
});
test('report decoder rejects stale, malformed and fake-connected success', () => {
  const good = success();
  for (const raw of ['null', '{}', JSON.stringify({ ...good, requestId: 'old' }),
    JSON.stringify({ ...good, tunnelConnected: true }), JSON.stringify({ ...good, destroyed: false }),
    JSON.stringify({ ...good, descriptorClosed: 'yes' }), JSON.stringify({ ...good, error: 'hidden' })]) {
    assert.throws(() => model.readVpnProbe(raw, '123-456'));
  }
});
test('request waits past stale snapshots and stops only the started extension', async () => {
  let reads = 0, stops = 0;
  const p = { start: async () => {}, stop: async () => { stops++; }, delay: async () => {},
    read: () => JSON.stringify(success(++reads === 1 ? 'old' : '123-456')) };
  const report = await client.requestVpnProbe(p, '123-456', () => false);
  assert.equal(report.ok, true);
  assert.equal(reads, 2);
  assert.equal(stops, 1);
});
test('authorization timeout is bounded and does not invent runtime or cleanup evidence', async () => {
  let waits = 0, stops = 0;
  const p = { start: async () => {}, stop: async () => { stops++; }, read: () => '', delay: async () => { waits++; } };
  await assert.rejects(client.requestVpnProbe(p, '1', () => false), /timed out.*cleanup remains unverified/);
  assert.equal(waits, 30);
  assert.equal(stops, 1);
});
test('failed start never stops an extension it did not start', async () => {
  let stops = 0;
  const p = { start: async () => { throw new Error('denied'); }, stop: async () => { stops++; } };
  await assert.rejects(client.requestVpnProbe(p, '1', () => false), /denied/);
  assert.equal(stops, 0);
});
test('request cancellation and stop errors remain explicit', async () => {
  let cancelled = false;
  const p = { start: async () => {}, stop: async () => { throw new Error('stop denied'); },
    read: () => '', delay: async () => { cancelled = true; } };
  await assert.rejects(client.requestVpnProbe(p, '1', () => cancelled), /cancelled.*stop denied/);
});

async function flushPromises() {
  for (let i = 0; i < 16; i++) await Promise.resolve();
}
test('unresolved SDK start is bounded; late start is cleaned once before a new request may run', async (t) => {
  t.mock.timers.enable({ apis: ['setTimeout', 'Date'], now: 1000 });
  let release, starts = 0, stops = 0;
  const p = { start: () => { starts++; return new Promise((resolve) => { release = resolve; }); },
    stop: async () => { stops++; }, read: () => '' };
  const failed = assert.rejects(client.requestVpnProbe(p, '1', () => false), /timed out at startVpnExtensionAbility/);
  t.mock.timers.tick(60000);
  await failed;
  assert.equal(stops, 0);
  await assert.rejects(client.requestVpnProbe(p, '2', () => false), /Previous VPN SDK operation/);
  assert.equal(starts, 1);
  release();
  await flushPromises();
  assert.equal(stops, 1);
  assert.equal((await client.requestVpnProbe({ start: async () => {}, stop: async () => {},
    read: () => JSON.stringify(success('2')) }, '2', () => false)).ok, true);
});
test('a timed-out stop cannot later tear down a newer request', async (t) => {
  t.mock.timers.enable({ apis: ['setTimeout', 'Date'], now: 1000 });
  let release, stops = 0;
  const p = { start: async () => {}, stop: () => { stops++; return new Promise((resolve) => { release = resolve; }); },
    read: () => JSON.stringify(success('1')) };
  const failed = assert.rejects(client.requestVpnProbe(p, '1', () => false), /timed out at stopVpnExtensionAbility/);
  await flushPromises();
  t.mock.timers.tick(10000);
  await failed;
  await assert.rejects(client.requestVpnProbe(p, '2', () => false), /Previous VPN SDK operation/);
  assert.equal(stops, 1);
  release();
  await flushPromises();
  assert.equal((await client.requestVpnProbe({ start: async () => {}, stop: async () => {},
    read: () => JSON.stringify(success('2')) }, '2', () => false)).ok, true);
});
test('a stalled report delay is bounded, retains the last stage and stops the started extension', async (t) => {
  t.mock.timers.enable({ apis: ['setTimeout', 'Date'], now: 1000 });
  let stops = 0;
  const stages = [];
  const partial = Object.assign(new model.VpnProbeReport(), { requestId: '1', stage: 'create' });
  const p = { start: async () => {}, stop: async () => { stops++; },
    read: () => JSON.stringify(partial), delay: () => new Promise(() => {}) };
  const failed = assert.rejects(client.requestVpnProbe(p, '1', () => false,
    (stage) => { stages.push(stage); }), /timed out at create/);
  await flushPromises();
  t.mock.timers.tick(30000);
  await failed;
  assert.deepEqual(stages, ['startVpnExtensionAbility', 'awaitExtensionReport', 'create', 'stopVpnExtensionAbility']);
  assert.equal(stops, 1);
});
test('unmount while SDK start is unresolved cancels promptly and later cleans only its acquired extension', async (t) => {
  t.mock.timers.enable({ apis: ['setTimeout', 'Date'], now: 1000 });
  let cancelled = false, release, stops = 0;
  const p = { start: () => new Promise((resolve) => { release = resolve; }), stop: async () => { stops++; } };
  const failed = assert.rejects(client.requestVpnProbe(p, '1', () => cancelled), /cancelled at startVpnExtensionAbility/);
  cancelled = true;
  t.mock.timers.tick(250);
  await failed;
  assert.equal(stops, 0);
  release();
  await flushPromises();
  assert.equal(stops, 1);
});
test('late SDK rejection releases the request lease without stopping an unowned extension', async (t) => {
  t.mock.timers.enable({ apis: ['setTimeout', 'Date'], now: 1000 });
  let rejectStart, stops = 0;
  const p = { start: () => new Promise((_resolve, reject) => { rejectStart = reject; }), stop: async () => { stops++; } };
  const failed = assert.rejects(client.requestVpnProbe(p, '1', () => false), /timed out/);
  t.mock.timers.tick(60000);
  await failed;
  rejectStart(new Error('late denial'));
  await flushPromises();
  assert.equal(stops, 0);
  assert.equal((await client.requestVpnProbe({ start: async () => {}, stop: async () => {},
    read: () => JSON.stringify(success('2')) }, '2', () => false)).ok, true);
});
test('controller publishes acquisition, protection, inspection and cleanup phases', async () => {
  const phases = [];
  const p = port();
  const report = await new model.VpnProbeController().run(p.value, '1', (partial) => {
    phases.push(JSON.parse(JSON.stringify(partial)));
  });
  assert.equal(report.ok, true);
  assert.deepEqual(phases.map((x) => x.stage), ['create', 'protectProcessNet', 'inspectDescriptor', 'cleanup']);
  assert.equal(phases[0].created, false);
  assert.equal(phases[1].created, true);
  assert.equal(phases[2].processProtected, true);
  assert.equal(phases[3].descriptorClosed, false);
});
test('progress persistence failure cannot prevent cleanup of an acquired descriptor', async () => {
  const p = port();
  const report = await new model.VpnProbeController().run(p.value, '1', (partial) => {
    if (partial.created) throw new Error('report write denied');
  });
  assert.equal(report.ok, false);
  assert.match(report.error, /report write denied/);
  assert.equal(report.descriptorClosed, true);
  assert.equal(report.destroyed, true);
  assert.deepEqual(p.calls, ['create', ['close', 17], 'destroy']);
});
test('extension executes actual SDK configuration with no Tailnet/default route or DNS override', async () => {
  const files = new Map(), writes = new Map(), closed = [], config = [];
  let complete;
  const finished = new Promise((resolve) => { complete = resolve; });
  const fileIo = {
    OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4 },
    openSync: (name) => { writes.set(99, name); return { fd: 99 }; },
    writeSync: (fd, value) => { files.set(writes.get(fd), value); },
    closeSync: (value) => { if (typeof value === 'number') closed.push(value); },
    renameSync: (from, to) => { files.set(to, files.get(from)); if (JSON.parse(files.get(to)).stage === 'complete') complete(); }
  };
  const store = compile('VpnProbeStore', { '@kit.CoreFileKit': { fileIo } });
  const connection = { create: async (value) => { config.push(value); return 17; },
    protectProcessNet: async () => {}, destroy: async () => {} };
  const ability = compile('VpnProbeAbility', {
    '@kit.AbilityKit': {},
    '@kit.NetworkKit': { VpnExtensionAbility: class {}, vpnExtension: { createVpnConnection: () => connection } },
    '@kit.CoreFileKit': { fileIo }, '@kit.PerformanceAnalysisKit': { hilog: { info() {}, error() {} } },
    'libtailscale_napi.so': { default: { inspectVpnDescriptor: async () => inspected } },
    './VpnProbeModel': model, './VpnProbeStore': store,
    './VpnSessionModel': sessionModel, './VpnSessionPlatform': {}, './VpnSessionStore': {},
    './NetworkServiceModel': { NetworkServiceActor: class { cancel() {} } }, './NetworkServicePlatform': {}, './NetworkServiceStore': {}
  }).default;
  const instance = new ability();
  instance.context = { filesDir: '/private' };
  instance.onCreate({ parameters: { probeRequestId: '123-456' } });
  await finished;
  const report = model.readVpnProbe(files.get('/private/vpn-capability-probe.json'), '123-456');
  assert.equal(report.ok, true);
  assert.equal(report.tunnelConnected, false);
  assert.deepEqual(config, [{ addresses: [{ address: { address: '192.0.2.1', family: 1 }, prefixLength: 32 }],
    routes: [], mtu: 1280, isIPv4Accepted: true, isIPv6Accepted: false }]);
  assert.deepEqual(closed, [17]);
});
