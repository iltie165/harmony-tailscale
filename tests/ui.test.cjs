'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const Module = require('node:module');
const path = require('node:path');
const ts = require(process.env.TYPESCRIPT_MODULE);
const root = path.resolve(__dirname, '..');
function compile(source, name, dependencies = {}) {
  const compiled = ts.transpileModule(source, {
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
  }).outputText;
  const mod = new Module(path.join(__dirname, name), module);
  mod.filename = path.join(__dirname, name);
  mod.require = (id) => Object.hasOwn(dependencies, id) ? dependencies[id] : require(id);
  mod._compile(compiled, mod.filename);
  return mod.exports;
}
const model = compile(fs.readFileSync(path.join(root, 'entry/src/main/ets/pages/ClientModel.ets'), 'utf8'), 'model.cjs');
const vpnModel = compile(fs.readFileSync(path.join(root, 'entry/src/main/ets/vpn/VpnProbeModel.ets'), 'utf8'), 'vpn-model.cjs');
const vpnClient = compile(fs.readFileSync(path.join(root, 'entry/src/main/ets/vpn/VpnProbeClient.ets'), 'utf8'), 'vpn-client.cjs', {
  './VpnProbeModel': vpnModel
});
const loggedOut = { ok: true, backendState: 'NeedsLogin', loggedIn: false };
const running = {
  ok: true, backendState: 'Running', loggedIn: true, tailscaleIPs: ['100.64.1.1'],
  self: { id: 'self', online: true, userLogin: 'test@example.com' },
  tailnet: { name: 'test.net', magicDNSSuffix: 'test.ts.net' }
};
const onlinePeer = { id: 'one', online: true, hostName: 'test-host', os: 'linux', tailscaleIPs: ['100.64.1.2'] };
function harness(overrides = {}, vpnOverrides = {}) {
  const calls = [];
  const probeCalls = [];
  let probeId = '';
  const vpnExtension = {
    startVpnExtensionAbility: async (want) => { probeCalls.push('start'); probeId = want.parameters.probeRequestId; },
    stopVpnExtensionAbility: async () => { probeCalls.push('stop'); },
    ...vpnOverrides
  };
  const platform = compile(fs.readFileSync(path.join(root, 'entry/src/main/ets/vpn/VpnProbePlatform.ets'), 'utf8'), 'vpn-platform.cjs', {
    '@kit.AbilityKit': {}, '@kit.NetworkKit': { vpnExtension },
    '@kit.CoreFileKit': { fileIo: {
      accessSync: () => true,
      readTextSync: () => JSON.stringify(Object.assign(new vpnModel.VpnProbeReport(), {
        requestId: probeId, ok: true, stage: 'complete', created: true, descriptorValid: true,
        readWriteDescriptor: true, processProtected: true, descriptorClosed: true, destroyed: true
      }))
    } },
    './VpnProbeClient': vpnClient,
    './VpnProbeStore': { vpnProbePath: (dir) => `${dir}/vpn-capability-probe.json` }
  });
  const native = {
    start: async () => { calls.push('start'); return JSON.stringify({ ok: true, state: 'started' }); },
    getStatus: async () => { calls.push('status'); return JSON.stringify(running); },
    onlinePeers: async (filter) => { calls.push(['peers', filter]); return JSON.stringify({ ok: true, peers: [onlinePeer] }); },
    login: async () => { calls.push('login'); return JSON.stringify({ ...loggedOut, authUrl: 'https://login.tailscale.com/a/private' }); },
    logout: async () => JSON.stringify(loggedOut),
    close: async () => JSON.stringify({ ok: true, state: 'closed' }),
    ...overrides
  };
  const emitter = { on() {}, off() {}, emit() {} };
  const full = fs.readFileSync(path.join(root, 'entry/src/main/ets/pages/Index.ets'), 'utf8');
  // Execute the actual production methods, not a duplicate controller. ArkUI
  // builders and decorators are compiler-only and remain verified by Hvigor.
  const marker = full.indexOf('  @Builder\n');
  assert.ok(marker > 0, 'UI method/compiler boundary must exist');
  const source = full.slice(0, marker)
    .replace('@Entry\n@Component\nstruct Index', 'export class Index')
    .replace(/@State /g, '') + '\n}\n';
  const { Index } = compile(source, 'index.cjs', {
    '@kit.AbilityKit': {}, '@kit.BasicServicesKit': { emitter },
    '@kit.PerformanceAnalysisKit': { hilog: { info() {} } },
    'libtailscale_napi.so': { default: native }, './ClientModel': model,
    '../vpn/VpnProbeClient': vpnClient,
    '../vpn/VpnProbePlatform': platform
  });
  const ui = new Index();
  ui.mounted = true;
  ui.dataDir = '/private/tailscale';
  ui.appContext = {
    filesDir: '/private',
    openLink: async (url) => { calls.push(['browser', url]); },
    startAbility: async () => { calls.push('fallback'); }
  };
  return { ui, calls, probeCalls };
}

test('VPN diagnostic UI preserves login and never treats capability success as tunnel connectivity', async () => {
  const { ui, calls, probeCalls } = harness();
  ui.status = running;
  ui.peers = [onlinePeer];
  await ui.runVpnProbe();
  assert.equal(ui.status, running);
  assert.equal(ui.peers[0], onlinePeer);
  assert.deepEqual(calls, []);
  assert.deepEqual(probeCalls, ['start', 'stop']);
  assert.equal(JSON.parse(ui.output).tunnelConnected, false);
  assert.match(ui.message, /尚未验证 Tailnet/);
  assert.equal(ui.busy, false);
});
test('VPN diagnostic denied authorization is explicit and retains authenticated UI', async () => {
  const { ui, probeCalls } = harness({}, { startVpnExtensionAbility: async () => { throw new Error('authorization denied'); } });
  ui.status = running;
  await ui.runVpnProbe();
  assert.match(ui.output, /authorization denied/);
  assert.equal(ui.status, running);
  assert.deepEqual(probeCalls, []);
  assert.equal(ui.busy, false);
});
test('VPN diagnostic finishing after unmount stops the extension without changing UI', async () => {
  let release;
  const { ui, probeCalls } = harness({}, { startVpnExtensionAbility: () => new Promise((resolve) => { release = resolve; }) });
  ui.output = 'previous';
  const pending = ui.runVpnProbe();
  await ui.runVpnProbe(); // busy suppresses a second acquisition
  const beforeUnmount = ui.output;
  ui.aboutToDisappear();
  release();
  await pending;
  assert.equal(ui.output, beforeUnmount);
  assert.deepEqual(probeCalls, ['stop']);
  assert.equal(ui.busy, false);
});

test('a pending SDK start times out with a visible stage and releases the UI', async (t) => {
  t.mock.timers.enable({ apis: ['setTimeout', 'Date'], now: 1000 });
  let release;
  const { ui, probeCalls } = harness({}, {
    startVpnExtensionAbility: () => new Promise((resolve) => { release = resolve; })
  });
  ui.status = running;
  const pending = ui.runVpnProbe();
  assert.match(ui.progress, /60 秒/);
  t.mock.timers.tick(60000);
  await pending;
  assert.equal(ui.busy, false);
  assert.equal(ui.progress, '');
  assert.equal(ui.status, running);
  assert.match(ui.output, /timed out at startVpnExtensionAbility/);
  assert.match(ui.message, /尚未确认清理/);
  assert.deepEqual(probeCalls, []);
  release();
  for (let i = 0; i < 12; i++) await Promise.resolve();
  assert.deepEqual(probeCalls, ['stop']);
});

test('dashboard requires a successful, Running, authenticated backend response', () => {
  assert.equal(model.isAuthenticated(running), true);
  for (const bad of [loggedOut, {}, { ...running, ok: false }, { ...running, backendState: 'Stopped' }, { ...running, loggedIn: false }]) {
    assert.equal(model.isAuthenticated(bad), false);
  }
});
test('backend errors and malformed responses are not displayed as an empty successful list', () => {
  assert.throws(() => model.readPeers('{"ok":false,"error":"ACL group unsupported"}'), /ACL group/);
  assert.throws(() => model.readControl('{"ok":false,"error":"control timeout"}'), /control timeout/);
  assert.throws(() => model.readPeers('{"ok":true,"peers":null}'));
  assert.throws(() => model.readControl('null'));
  assert.throws(() => model.readControl('not json'));
});
test('only explicitly online devices are counted, optional peer fields have safe fallbacks', () => {
  const peers = model.readPeers(JSON.stringify({ ok: true, peers: [onlinePeer, { id: 'off', online: false }] }));
  assert.equal(peers.length, 1);
  assert.equal(model.peerName({ id: 'blank', online: true }), '未命名设备');
  assert.equal(model.peerAddress({ id: 'blank', online: true }), '暂无 Tailscale IP');
  assert.equal(model.osLabel('darwin'), 'macOS');
  assert.equal(model.osLabel('customOS'), 'customOS');
});
test('diagnostic rendering redacts one-time login URL without discarding error evidence', () => {
  const output = model.safeOutput(JSON.stringify({ authUrl: 'https://login.tailscale.com/a/private', error: 'control timeout' }));
  assert.ok(!output.includes('/a/private'));
  assert.ok(output.includes('control timeout'));
});
test('restoring a persisted login loads real peers without opening a browser', async () => {
  const { ui, calls } = harness();
  await ui.restoreSession();
  assert.equal(model.isAuthenticated(ui.status), true);
  assert.equal(ui.peers.length, 1);
  assert.ok(!calls.some((c) => Array.isArray(c) && c[0] === 'browser'));
  assert.equal(ui.busy, false);
});
test('fresh NeedsLogin starts quietly and never launches a browser automatically', async () => {
  const { ui, calls } = harness({ getStatus: async () => JSON.stringify(loggedOut) });
  await ui.restoreSession();
  assert.equal(model.isAuthenticated(ui.status), false);
  assert.equal(ui.peers.length, 0);
  assert.deepEqual(calls, ['start']);
  ui.stopPolling();
});
test('interactive login opens the exact URL once and reports waiting instead of VPN-connected', async () => {
  const { ui, calls } = harness();
  await ui.login();
  ui.stopPolling();
  assert.equal(calls.filter((c) => Array.isArray(c) && c[0] === 'browser').length, 1);
  assert.equal(ui.awaitingLogin, true);
  assert.equal(model.isAuthenticated(ui.status), false);
  assert.equal(ui.busy, false);
  assert.ok(!ui.output.includes('/a/private'));
});
test('returning after successful browser auth clears polling and fills devices', async () => {
  const { ui } = harness();
  ui.awaitingLogin = true;
  ui.loginDeadline = Date.now() + 10000;
  await ui.refreshData();
  assert.equal(ui.awaitingLogin, false);
  assert.equal(ui.pollTimer, -1);
  assert.equal(ui.peers.length, 1);
});
test('native login errors retain diagnostic JSON and never attempt browser dispatch', async () => {
  const { ui, calls } = harness({ login: async () => JSON.stringify({ ok: false, error: 'deadline', debugLogs: ['control dial failed'] }) });
  await ui.login();
  assert.match(ui.message, /deadline/);
  assert.match(ui.output, /control dial failed/);
  assert.ok(!calls.some((c) => Array.isArray(c) && c[0] === 'browser'));
});
test('browser dispatch failure uses platform fallback and does not log URL', async () => {
  const { ui, calls } = harness();
  ui.appContext.openLink = async () => { throw new Error('openLink unavailable'); };
  await ui.login();
  ui.stopPolling();
  assert.ok(calls.includes('fallback'));
  assert.equal(ui.awaitingLogin, true);
});
test('peer refresh failure clears stale online devices, preserves backend error', async () => {
  const { ui } = harness({ onlinePeers: async () => JSON.stringify({ ok: false, error: 'group unsupported' }) });
  ui.peers = [onlinePeer];
  ui.lastUpdated = 'yesterday';
  await ui.refreshData();
  assert.equal(ui.peers.length, 0);
  assert.equal(ui.lastUpdated, '');
  assert.match(ui.message, /group unsupported/);
  assert.equal(ui.busy, false);
});
test('logout failure retains account; successful logout clears account/device UI', async () => {
  const failing = harness({ logout: async () => JSON.stringify({ ok: false, error: 'offline' }) }).ui;
  failing.status = running;
  failing.peers = [onlinePeer];
  await failing.logout();
  assert.equal(model.isAuthenticated(failing.status), true);
  assert.equal(failing.peers.length, 1);
  assert.match(failing.message, /offline/);
  const success = harness().ui;
  success.status = running;
  success.peers = [onlinePeer];
  await success.logout();
  assert.equal(model.isAuthenticated(success.status), false);
  assert.equal(success.peers.length, 0);
});
test('repeated UI login clicks are rejected while native request is in flight', async () => {
  let release;
  const pending = new Promise((resolve) => { release = resolve; });
  const { ui, calls } = harness({ login: async () => { await pending; return JSON.stringify(running); } });
  const first = ui.login();
  await ui.login();
  release();
  await first;
  assert.equal(calls.filter((c) => c === 'start').length, 1);
});
test('navigation back and close distinguish stopping core from deleting account state', async () => {
  const { ui } = harness();
  ui.page = 'diagnostics';
  assert.equal(ui.onBackPress(), true);
  assert.equal(ui.page, 'settings');
  assert.equal(ui.onBackPress(), true);
  assert.equal(ui.page, 'main');
  assert.equal(ui.onBackPress(), false);
  ui.status = running;
  ui.peers = [onlinePeer];
  await ui.diagnostic('close');
  assert.equal(model.isAuthenticated(ui.status), false);
  assert.equal(ui.peers.length, 0);
});
test('persisted session can become Running after the first startup snapshot', async () => {
  let reads = 0;
  const { ui } = harness({ getStatus: async () => JSON.stringify(++reads === 1 ? loggedOut : running) });
  await ui.restoreSession();
  assert.equal(model.isAuthenticated(ui.status), false);
  assert.notEqual(ui.pollTimer, -1);
  ui.stopPolling();
  await ui.refreshData();
  assert.equal(model.isAuthenticated(ui.status), true);
  assert.equal(ui.restoreDeadline, 0);
  assert.equal(ui.pollTimer, -1);
});
test('expired login polling is bounded and unmount cancels pending work', () => {
  const { ui } = harness();
  ui.awaitingLogin = true;
  ui.loginDeadline = Date.now() - 1;
  ui.scheduleLoginRefresh();
  assert.equal(ui.awaitingLogin, false);
  assert.equal(ui.pollTimer, -1);
  ui.awaitingLogin = true;
  ui.loginDeadline = Date.now() + 10000;
  ui.scheduleLoginRefresh();
  assert.notEqual(ui.pollTimer, -1);
  ui.aboutToDisappear();
  assert.equal(ui.mounted, false);
  assert.equal(ui.pollTimer, -1);
});

test('Go-produced status/peer/lifecycle fixtures obey the actual UI decoder contract', (t) => {
  const dir = process.env.HARMONY_CONTRACT_DIR;
  if (!dir || !fs.existsSync(path.join(dir, 'running.json'))) {
    t.skip('run scripts/test-server.sh to generate Go producer fixtures'); return;
  }
  const fixture = (name) => fs.readFileSync(path.join(dir, `${name}.json`), 'utf8');
  assert.equal(model.isAuthenticated(model.readControl(fixture('running'))), true);
  assert.equal(model.readPeers(fixture('peers')).length, 2);
  assert.equal(model.readPeers(fixture('emptyPeers')).length, 0);
  assert.equal(model.readControl(fixture('started')).state, 'started');
  assert.equal(model.readControl(fixture('closed')).state, 'closed');
  assert.throws(() => model.readControl(fixture('statusFailure')), /control unavailable/);
  assert.throws(() => model.readPeers(fixture('groupFailure')), /ACL group/);
});
test('malformed native field types are rejected before rendering or browser dispatch', () => {
  for (const result of [
    { ...running, loggedIn: 'yes' }, { ...running, backendState: 1 },
    { ...running, authUrl: 42 }, { ...running, tailscaleIPs: '100.64.1.1' },
    { ...running, tailnet: null }, { ...running, self: { id: 42, online: true } }
  ]) assert.throws(() => model.readControl(JSON.stringify(result)));
  for (const peer of [null, 42, { id: 'a' }, { ...onlinePeer, os: 1 },
    { ...onlinePeer, tags: 'tag:server' }, { ...onlinePeer, tailscaleIPs: [42] }]) {
    assert.throws(() => model.readPeers(JSON.stringify({ ok: true, peers: [peer] })));
  }
});
test('browser double failure is visible and does not start login polling', async () => {
  const { ui } = harness();
  ui.appContext.openLink = async () => { throw new Error('primary denied'); };
  ui.appContext.startAbility = async () => { throw new Error('fallback denied'); };
  await ui.login();
  assert.equal(ui.awaitingLogin, false);
  assert.equal(ui.pollTimer, -1);
  assert.match(ui.message, /primary denied/);
  assert.match(ui.message, /fallback denied/);
});
test('a pending login finishing after unmount must not open the system browser', async () => {
  let release;
  const pending = new Promise((resolve) => { release = resolve; });
  const { ui, calls } = harness({ login: async () => {
    await pending; return JSON.stringify({ ...loggedOut, authUrl: 'https://login.tailscale.com/a/token' });
  } });
  const operation = ui.login();
  await new Promise((resolve) => setImmediate(resolve));
  ui.aboutToDisappear();
  release(); await operation;
  assert.ok(!calls.some((c) => Array.isArray(c) && c[0] === 'browser'));
  assert.equal(ui.pollTimer, -1);
});
test('device response after unmount is not applied to a detached page', async () => {
  let release;
  const pending = new Promise((resolve) => { release = resolve; });
  const { ui } = harness({ onlinePeers: async () => { await pending; return JSON.stringify({ ok: true, peers: [onlinePeer] }); } });
  const operation = ui.refreshData();
  await new Promise((resolve) => setImmediate(resolve));
  ui.aboutToDisappear();
  release(); await operation;
  assert.equal(ui.peers.length, 0);
  assert.equal(ui.lastUpdated, '');
});
test('polling timer advances and stops deterministically without real waiting', async (t) => {
  t.mock.timers.enable({ apis: ['setTimeout', 'Date'], now: 1000 });
  const { ui } = harness({ getStatus: async () => JSON.stringify(loggedOut) });
  ui.awaitingLogin = true; ui.loginDeadline = 10000;
  ui.scheduleLoginRefresh();
  t.mock.timers.tick(2000);
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(ui.busy, false);
  assert.notEqual(ui.pollTimer, -1);
  t.mock.timers.tick(10000);
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(ui.awaitingLogin, false);
  assert.equal(ui.pollTimer, -1);
});
test('background polling does not issue native requests', (t) => {
  t.mock.timers.enable({ apis: ['setTimeout', 'Date'], now: 1000 });
  const { ui, calls } = harness();
  ui.foreground = false; ui.awaitingLogin = true; ui.loginDeadline = 10000;
  ui.scheduleLoginRefresh(); t.mock.timers.tick(2000);
  assert.deepEqual(calls, []);
  ui.aboutToDisappear();
});
test('logout/status transitions clear device detail and never leave stale online cards', async () => {
  const { ui } = harness({ getStatus: async () => JSON.stringify(loggedOut) });
  ui.status = running; ui.page = 'detail'; ui.selectedPeer = onlinePeer; ui.peers = [onlinePeer];
  await ui.refreshData();
  assert.equal(ui.page, 'main');
  assert.equal(ui.selectedPeer, undefined);
  assert.deepEqual(ui.peers, []);
});
