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
const model = compile('VpnSessionModel');
const client = compile('VpnSessionClient', { './VpnSessionModel': model });
const connected = () => Object.assign(new model.VpnState(), {
  connected: true, state: 'connected', ipv4: '100.64.1.1', txPackets: 4, rxPackets: 2
});
function port(overrides = {}) {
  const calls = [];
  return { calls, value: {
    create: async (ip) => { calls.push(['create', ip]); return 19; },
    protect: async () => { calls.push('protect'); },
    attach: async (fd, ip) => { calls.push(['attach', fd, ip]); return '{"ok":true}'; },
    closeDescriptor: (fd) => { calls.push(['closeDescriptor', fd]); },
    status: async () => { calls.push('status'); return JSON.stringify(connected()); },
    closeCore: async () => { calls.push('closeCore'); return '{"ok":true}'; },
    destroy: async () => { calls.push('destroy'); },
    stopping: () => false,
    delay: async () => {},
    ...overrides
  } };
}
test('real session protects transport before starting core, holds VPN open, then stops without logout', async () => {
  const p = port(); const controller = new model.VpnSessionController(); const seen = [];
  const result = await controller.run(p.value, '1-2', '100.64.1.1', (r) => {
    seen.push(JSON.parse(JSON.stringify(r)));
    if (r.connected) { controller.cancel(); }
  });
  assert.deepEqual(p.calls, [['create', '100.64.1.1'], 'protect', ['attach', 19, '100.64.1.1'],
    ['closeDescriptor', 19], 'status', 'closeCore', 'destroy']);
  const live = seen.find((r) => r.connected);
  assert.equal(live.txPackets, 4); assert.equal(live.rxPackets, 2);
  assert.equal(live.destroyed, false);
  assert.equal(result.stage, 'stopped'); assert.equal(result.connected, false);
  assert.equal(result.coreClosed, true); assert.equal(result.destroyed, true);
});
test('stop command is honored before first status poll, never claims a connection', async () => {
  const p = port({ stopping: () => true }); const seen = [];
  const r = await new model.VpnSessionController().run(p.value, '1', '100.64.1.1', (s) => { seen.push(s.connected); });
  assert.equal(r.ok, true); assert.ok(!seen.some(Boolean)); assert.ok(!p.calls.includes('status'));
});
test('invalid address or denied create does not close unrelated resources', async () => {
  for (const ip of ['192.168.1.1', '100.063.1.1', 'fd7a::1', '100.64.1.300']) {
    const p = port(); const r = await new model.VpnSessionController().run(p.value, '1', ip, () => {});
    assert.equal(r.ok, false); assert.deepEqual(p.calls, []);
  }
  const p = port({ create: async () => { throw new Error('authorization denied'); } });
  const r = await new model.VpnSessionController().run(p.value, '1', '100.64.1.1', () => {});
  assert.match(r.error, /authorization denied/); assert.deepEqual(p.calls, []);
});
test('protection and attach errors fail closed and retain each cleanup result', async () => {
  for (const stage of ['protect', 'attach', 'status']) {
    const p = port({ [stage]: async () => { throw new Error(`${stage} failed`); } });
    const r = await new model.VpnSessionController().run(p.value, '1', '100.64.1.1', () => {});
    assert.equal(r.connected, false); assert.equal(r.stage, 'failed'); assert.match(r.error, /failed/);
    assert.equal(r.destroyed, true); assert.equal(r.descriptorClosed, true);
    assert.equal(p.calls.includes('closeCore'), stage !== 'protect');
    assert.equal(p.calls.filter((x) => Array.isArray(x) && x[0] === 'closeDescriptor').length, 1);
  }
});
test('failed native attach result or mismatched IP cannot be shown connected', async () => {
  for (const overrides of [
    { attach: async () => '{"ok":false,"error":"state lease held"}' },
    { status: async () => JSON.stringify({ ...connected(), ipv4: '100.64.1.2' }) },
    { status: async () => JSON.stringify({ ...connected(), ok: false, error: 'packet read failed' }) }
  ]) {
    const p = port(overrides); let everConnected = false;
    const r = await new model.VpnSessionController().run(p.value, '1', '100.64.1.1', (s) => { everConnected ||= s.connected; });
    assert.equal(everConnected, false); assert.equal(r.ok, false); assert.equal(r.coreClosed, true);
  }
});
test('late create after extension cancellation closes acquired FD and never starts core', async () => {
  let release;
  const p = port({ create: () => new Promise((resolve) => { release = resolve; }) });
  const controller = new model.VpnSessionController();
  const work = controller.run(p.value, '1', '100.64.1.1', () => {});
  controller.cancel(); release(23);
  const r = await work;
  assert.equal(r.connected, false); assert.equal(r.destroyed, true);
  assert.deepEqual(p.calls, [['closeDescriptor', 23], 'destroy']);
});
test('cleanup failure never emits successful disconnected state and destroy still runs', async () => {
  const p = port({ stopping: () => true, closeCore: async () => '{"ok":false,"error":"shutdown failed"}' });
  const r = await new model.VpnSessionController().run(p.value, '1', '100.64.1.1', () => {});
  assert.equal(r.ok, false); assert.equal(r.state, 'error'); assert.equal(r.coreClosed, false);
  assert.equal(r.destroyed, true); assert.match(r.error, /shutdown failed/);
});

test('original close is attempted once even when it errors; core and platform cleanup still run', async () => {
  let attempts = 0;
  const p = port({ closeDescriptor: () => { attempts++; throw new Error('close failed'); } });
  const r = await new model.VpnSessionController().run(p.value, '1', '100.64.1.1', () => {});
  assert.equal(attempts, 1); assert.equal(r.descriptorClosed, false);
  assert.equal(r.coreClosed, true); assert.equal(r.destroyed, true); assert.equal(r.ok, false);
});

test('platform session installs only IPv4 Tailnet route, adapts callback monitor, and always closes core', async () => {
  const calls = []; const handlers = {}; let config;
  const monitor = { register: (cb) => { calls.push('register'); cb(); },
    unregister: (cb) => { calls.push('unregister'); cb({ code: 7, message: 'monitor gone' }); },
    on: (name, handler) => { handlers[name] = handler; } };
  const platform = compile('VpnSessionPlatform', {
    '@kit.NetworkKit': { connection: { createNetConnection: () => monitor } },
    '@kit.CoreFileKit': { fileIo: { closeSync: (fd) => { calls.push(['close', fd]); } } },
    '@kit.BasicServicesKit': {}, '@kit.PerformanceAnalysisKit': { hilog: { warn() {} } },
    './VpnSessionModel': model, './VpnSessionStore': { stopRequested: () => false },
    './VpnSessionClient': client,
    '../pages/PlatformInfo': { configurePlatformInfo: async () => {} },
    'libtailscale_napi.so': { default: {
      startVpn: async (...args) => { calls.push(['attach', ...args]); return '{"ok":true}'; },
      networkChanged: async () => { calls.push('networkChanged'); return '{"ok":true}'; },
      close: async () => { calls.push('closeCore'); return '{"ok":true}'; }
    } }
  });
  const session = new platform.PlatformVpnSession({
    create: async (c) => { config = c; return 31; }, protectProcessNet: async () => {}, destroy: async () => {}
  }, '/private', 'host', '1');
  await session.create('100.64.1.1');
  assert.deepEqual(config.addresses, [{ address: { address: '100.64.1.1', family: 1 }, prefixLength: 32 }]);
  assert.equal(config.routes[0].destination.address.address, '100.64.0.0');
  assert.equal(config.routes[0].destination.prefixLength, 10); assert.equal(config.routes[0].isDefaultRoute, false);
  assert.equal(config.dnsAddresses, undefined); assert.equal(config.isIPv6Accepted, false);
  await session.attach(31, '100.64.1.1');
  assert.deepEqual(calls[0], ['attach', '/private/tailscale', 'host', '100.64.1.1', 31]);
  handlers.netLost(); await flush(); assert.ok(calls.includes('networkChanged'));
  assert.equal(JSON.parse(await session.closeCore()).ok, true);
  const before = calls.filter((c) => c === 'networkChanged').length;
  handlers.netAvailable(); await flush(); assert.equal(calls.filter((c) => c === 'networkChanged').length, before);
  assert.ok(calls.includes('unregister')); assert.equal(calls.at(-1), 'closeCore');
});
test('control connection timeout performs full cleanup', async (t) => {
  t.mock.timers.enable({ apis: ['Date'], now: 1 });
  const p = port({ status: async () => JSON.stringify({ ...connected(), connected: false, state: 'connecting' }),
    delay: async () => { t.mock.timers.tick(46000); } });
  const r = await new model.VpnSessionController().run(p.value, '1', '100.64.1.1', () => {});
  assert.match(r.error, /control connection timed out/); assert.equal(r.coreClosed, true); assert.equal(r.destroyed, true);
});
function report(id = '1') { return Object.assign(new model.VpnSessionReport(), connected(), {
  requestId: id, stage: 'connected', created: true, processProtected: true, descriptorClosed: true
}); }
function request(overrides = {}) {
  const calls = []; let snapshot = report();
  return { calls, value: {
    start: async () => { calls.push('sdkStart'); },
    stop: async () => { calls.push('sdkStop'); },
    read: () => JSON.stringify(snapshot),
    requestStop: (id) => { calls.push(['stopCommand', id]); snapshot = { ...report(id), connected: false, state: 'disconnected', stage: 'stopped', coreClosed: true, destroyed: true }; },
    delay: async () => {},
    ...overrides
  } };
}
test('client leaves a connected extension running until an explicit OFF command', async () => {
  const p = request(); const r = await client.startVpnSession(p.value, '1', () => false, () => {});
  assert.equal(r.connected, true); assert.deepEqual(p.calls, ['sdkStart']);
  await client.stopVpnSession(p.value, '1');
  assert.deepEqual(p.calls, ['sdkStart', ['stopCommand', '1'], 'sdkStop']);
});
test('denied SDK authorization is identified as no acquired VPN, with no stray stop', async () => {
  const p = request({ start: async () => { throw new Error('user denied'); } });
  await assert.rejects(client.startVpnSession(p.value, '1', () => false, () => {}), (error) => {
    assert.equal(error.cleanupConfirmed, true); return /user denied/.test(error.message);
  });
  assert.deepEqual(p.calls, []); assert.equal(client.vpnSdkPending(), false);
});
test('cancelled client request stops its extension and verifies cleanup', async () => {
  const p = request();
  await assert.rejects(client.startVpnSession(p.value, '1', () => true, () => {}), (error) => error.cleanupConfirmed);
  assert.deepEqual(p.calls, ['sdkStart', ['stopCommand', '1'], 'sdkStop']);
});
test('stale report does not complete a new request', async () => {
  let reads = 0; const p = request({ read: () => JSON.stringify(report(reads++ ? '1' : 'previous')) });
  const r = await client.startVpnSession(p.value, '1', () => false, () => {});
  assert.equal(r.requestId, '1'); assert.equal(reads, 2);
});
async function flush() { for (let i = 0; i < 12; i++) await Promise.resolve(); }
test('timed out authorization keeps retry blocked until late startup and its cleanup settle', async (t) => {
  t.mock.timers.enable({ apis: ['Date', 'setTimeout'], now: 1 });
  let releaseStart, releaseStop;
  const p = request({ start: () => new Promise((resolve) => { releaseStart = resolve; }),
    stop: () => new Promise((resolve) => { releaseStop = resolve; }) });
  const work = client.startVpnSession(p.value, '1', () => false, () => {});
  const rejected = assert.rejects(work, (error) => !error.cleanupConfirmed && /timed out/.test(error.message));
  t.mock.timers.tick(60001); await rejected;
  assert.equal(client.vpnSdkPending(), true);
  await assert.rejects(client.startVpnSession(request().value, '2', () => false, () => {}), /still pending/);
  releaseStart(); await flush();
  assert.ok(releaseStop); assert.equal(client.vpnSdkPending(), true);
  releaseStop(); await flush(); assert.equal(client.vpnSdkPending(), false);
});
test('VPN status rejects malformed counters and inconsistent success', () => {
  for (const state of [null, {}, { ...connected(), txPackets: -1 }, { ...connected(), state: 'disconnected' },
    { ...connected(), ipv4: '192.168.1.1' }, { ...connected(), error: 'failed' }]) {
    assert.throws(() => model.readVpnState(JSON.stringify(state)), /Invalid VPN/);
  }
});
