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
const sessionModel = compile(fs.readFileSync(path.join(root, 'entry/src/main/ets/vpn/VpnSessionModel.ets'), 'utf8'), 'session-model.cjs');
const sessionClient = compile(fs.readFileSync(path.join(root, 'entry/src/main/ets/vpn/VpnSessionClient.ets'), 'utf8'), 'session-client.cjs', {
  './VpnSessionModel': sessionModel
});
const loggedOut = { ok: true, backendState: 'NeedsLogin', loggedIn: false };
const running = {
  ok: true, backendState: 'Running', loggedIn: true, tailscaleIPs: ['100.64.1.1'],
  self: { id: 'self', online: true, userLogin: 'test@example.com' },
  tailnet: { name: 'test.net', magicDNSSuffix: 'test.ts.net' }
};
const onlinePeer = { id: 'one', online: true, hostName: 'test-host', os: 'linux', tailscaleIPs: ['100.64.1.2'] };
function harness(overrides = {}, vpnOverrides = {}, probeReportOverrides = {}, sessionOverrides = {}) {
  const calls = [];
  let sessionLive = false;
  let sessionReport;
  class PlatformSessionRequest {
    constructor(_dir, id, ip) { this.id = id; this.ip = ip; }
    async start() {
      calls.push('vpnStart'); sessionLive = true;
      sessionReport = Object.assign(new sessionModel.VpnSessionReport(), {
        requestId: this.id, ipv4: this.ip, state: 'connected', stage: 'connected', connected: true,
        created: true, processProtected: true, descriptorClosed: true
      });
      if (sessionOverrides.start) await sessionOverrides.start(this, sessionReport);
    }
    async stop() { calls.push('vpnStop'); if (sessionOverrides.stop) await sessionOverrides.stop(); }
    read() { return sessionReport ? JSON.stringify(sessionReport) : ''; }
    requestStop(id) {
      calls.push(['vpnStopCommand', id]); sessionLive = false;
      Object.assign(sessionReport, { connected: false, state: 'disconnected', stage: 'stopped', coreClosed: true, destroyed: true });
      if (sessionOverrides.cleanup) Object.assign(sessionReport, sessionOverrides.cleanup);
    }
    async delay() {}
  }
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
        readWriteDescriptor: true, processProtected: true, descriptorClosed: true, destroyed: true,
        ...probeReportOverrides
      }))
    } },
    './VpnProbeClient': vpnClient,
    './VpnProbeStore': { vpnProbePath: (dir) => `${dir}/vpn-capability-probe.json` }
  });
  const native = {
    getVpnStatus: async () => JSON.stringify(Object.assign(new sessionModel.VpnState(), sessionLive ? {
      connected: true, state: 'connected', ipv4: '100.64.1.1', txPackets: 1, rxPackets: 2
    } : {})),
    start: async () => { calls.push('start'); return JSON.stringify({ ok: true, state: 'started' }); },
    getStatus: async () => { calls.push('status'); return JSON.stringify(running); },
    onlinePeers: async (filter) => { calls.push(['peers', filter]); return JSON.stringify({ ok: true, peers: [onlinePeer] }); },
    login: async () => { calls.push('login'); return JSON.stringify({ ...loggedOut, authUrl: 'https://login.tailscale.com/a/private' }); },
    logout: async () => JSON.stringify(loggedOut),
    close: async () => { calls.push('close'); return JSON.stringify({ ok: true, state: 'closed' }); },
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
    .replace(/@StorageLink\('[^']+'\) /g, '')
    .replace(/@State /g, '') + '\n}\n';
  const { Index } = compile(source, 'index.cjs', {
    '@kit.AbilityKit': {}, '@kit.BasicServicesKit': { emitter },
    '@kit.PerformanceAnalysisKit': { hilog: { info() {} } },
    'libtailscale_napi.so': { default: native }, './ClientModel': model,
    '../vpn/VpnProbeClient': vpnClient,
    '../vpn/VpnProbePlatform': platform,
    '../vpn/VpnSessionModel': sessionModel, '../vpn/VpnSessionClient': sessionClient,
    '../vpn/VpnSessionRequest': { PlatformSessionRequest }
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

test('main VPN toggle hands off discovery, reads independent live state, and OFF retains login', async () => {
  const { ui, calls } = harness(); ui.status = running;
  await ui.setVpn(true);
  assert.deepEqual(calls.slice(0, 3), ['close', 'vpnStart', 'start']);
  assert.equal(ui.vpn.connected, true); assert.equal(ui.vpn.rxPackets, 2);
  assert.equal(ui.vpnNeedsCleanup, false); assert.equal(ui.busy, false);
  assert.ok(ui.vpnTimer !== -1);
  await ui.setVpn(false);
  assert.equal(ui.vpn.connected, false); assert.equal(ui.vpnNeedsCleanup, false);
  assert.equal(ui.status.loggedIn, true); assert.equal(ui.peers.length, 1);
  assert.ok(calls.includes('vpnStop')); assert.ok(calls.some((x) => Array.isArray(x) && x[0] === 'vpnStopCommand'));
  assert.match(ui.message, /登录已保留/); ui.aboutToDisappear();
});
test('VPN toggle requires authenticated assigned IPv4 and suppresses duplicate busy actions', async () => {
  for (const status of [loggedOut, { ...running, tailscaleIPs: ['fd7a::1'] }]) {
    const { ui, calls } = harness(); ui.status = status;
    await ui.setVpn(true); assert.equal(ui.vpn.connected, false); assert.ok(!calls.includes('vpnStart'));
    assert.match(ui.message, /登录|IPv4/);
  }
  const { ui, calls } = harness(); ui.status = running; ui.busy = true;
  await ui.setVpn(true); assert.deepEqual(calls, []);
});
test('failed OFF leaves shutdown uncertain and retryable; it does not resume another core', async () => {
  const { ui, calls } = harness({}, {}, {}, { cleanup: { ok: false, stage: 'failed', state: 'error', coreClosed: false, error: 'core shutdown failed' } });
  ui.status = running; await ui.setVpn(true); calls.length = 0;
  await ui.setVpn(false);
  assert.equal(ui.vpnNeedsCleanup, true); assert.equal(ui.vpn.ok, false);
  assert.match(ui.message, /尚未确认关闭/); assert.ok(!calls.includes('start')); assert.ok(!calls.includes('close'));
  ui.aboutToDisappear();
});

test('failure to read peers after VPN startup never closes the owner or starts a competing discovery core', async () => {
  const { ui, calls } = harness({ onlinePeers: async () => { throw new Error('peer query timed out'); } });
  ui.status = running; await ui.setVpn(true);
  assert.equal(ui.vpnNeedsCleanup, true); assert.match(ui.message, /尚未确认关闭/);
  assert.equal(calls.filter((c) => c === 'close').length, 1);
  assert.equal(calls.filter((c) => c === 'start').length, 1);
  assert.ok(!calls.includes('vpnStop')); ui.aboutToDisappear();
});
test('VPN rejects conflicting diagnostic/probe controls and unmount does not turn it off', async () => {
  const { ui, calls } = harness(); ui.status = running; await ui.setVpn(true);
  calls.length = 0; await ui.diagnostic('close'); assert.match(ui.output, /主界面开关/);
  ui.confirmVpnProbe(); assert.match(ui.message, /先关闭 VPN/);
  ui.aboutToDisappear(); assert.deepEqual(calls, []); assert.equal(ui.vpn.connected, true);
});

test('temporarily reconnecting VPN remains ON and can still be explicitly disconnected', async () => {
  const { ui, calls } = harness(); ui.status = running; await ui.setVpn(true);
  ui.vpn.connected = false; ui.vpn.state = 'connecting';
  assert.equal(ui.vpnRunning(), true);
  ui.confirmVpnProbe(); assert.match(ui.message, /先关闭/);
  await ui.setVpn(false); assert.ok(calls.includes('vpnStop')); assert.equal(ui.vpnRunning(), false);
  ui.aboutToDisappear();
});
test('logging out while VPN is active confirms shutdown before deleting login state', async () => {
  const { ui, calls } = harness({ logout: async () => { calls.push('logout'); return JSON.stringify(loggedOut); } });
  ui.status = running; await ui.setVpn(true); await ui.logout();
  assert.ok(calls.indexOf('vpnStop') < calls.indexOf('logout'));
  assert.equal(ui.vpn.connected, false); assert.equal(ui.status.loggedIn, false); ui.aboutToDisappear();
});

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

test('metadata-restricted UI success is labelled basic capability, not packet or Tailnet verification', async () => {
  const { ui } = harness({}, {}, { warning: 'metadata access denied', packetIOVerified: false });
  await ui.runVpnProbe();
  assert.match(ui.message, /基础接口检查通过.*元数据查询受限.*尚未验证/);
  assert.equal(JSON.parse(ui.output).packetIOVerified, false);
  assert.equal(JSON.parse(ui.output).tunnelConnected, false);
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

test('dashboard uses account authentication independently of engine readiness', () => {
  assert.equal(model.isAuthenticated(running), true);
  for (const state of ['Starting', 'Stopped', 'NoState']) {
    assert.equal(model.isAuthenticated({ ...running, backendState: state }), true);
  }
  for (const bad of [loggedOut, {}, { ...running, ok: false }, { ...running, backendState: 'NeedsLogin' }, { ...running, loggedIn: false }]) {
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
  assert.equal(model.isAuthenticated(model.readControl(fixture('restoring'))), true);
  assert.equal(model.readPeers(fixture('peers')).length, 2);
  assert.equal(model.readPeers(fixture('emptyPeers')).length, 0);
  assert.equal(model.readControl(fixture('started')).state, 'started');
  assert.equal(model.readControl(fixture('closed')).state, 'closed');
  assert.throws(() => model.readControl(fixture('statusFailure')), /control unavailable/);
  assert.throws(() => model.readPeers(fixture('groupFailure')), /ACL group/);
});

test('cold launch restores saved account before Running and silently continues after startup window', async (t) => {
  t.mock.timers.enable({ apis: ['setTimeout', 'Date'], now: 1000 });
  let ready = false;
  const { ui, calls } = harness({ getStatus: async () => JSON.stringify({ ...running, backendState: ready ? 'Running' : 'Starting' }) });
  await ui.restoreSession();
  assert.equal(ui.restoringSession, false);
  assert.equal(model.isAuthenticated(ui.status), true);
  assert.equal(ui.vpn.connected, false);
  assert.equal(ui.peers.length, 0);
  assert.ok(!calls.includes('login'));
  assert.ok(!calls.some((c) => Array.isArray(c) && c[0] === 'peers'));
  t.mock.timers.tick(16000);
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(model.isAuthenticated(ui.status), true);
  assert.notEqual(ui.vpnTimer, -1);
  ready = true;
  t.mock.timers.tick(5000);
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(ui.peers.length, 1);
  assert.equal(ui.busy, false);
  assert.equal(ui.vpnTimer, -1);
  ui.aboutToDisappear();
});

test('VPN OFF preserves account through discovery restart, without login/logout/browser', async () => {
  let restarting = false;
  const { ui, calls } = harness({
    getStatus: async () => JSON.stringify({ ...running, backendState: restarting ? 'Starting' : 'Running' }),
    logout: async () => { throw new Error('OFF must never log out'); }
  });
  ui.status = running;
  await ui.setVpn(true);
  restarting = true;
  await ui.setVpn(false);
  assert.equal(ui.vpn.connected, false);
  assert.equal(model.isAuthenticated(ui.status), true);
  assert.equal(ui.peers.length, 0);
  assert.notEqual(ui.pollTimer, -1);
  assert.match(ui.message, /登录已保留/);
  assert.ok(!calls.includes('login'));
  assert.ok(!calls.some((c) => Array.isArray(c) && c[0] === 'browser'));
  restarting = false;
  await ui.refreshData(true);
  assert.equal(ui.peers.length, 1);
  assert.equal(ui.pollTimer, -1);
  ui.aboutToDisappear();
});

test('saved account reconnecting cannot start VPN until core is ready', async () => {
  const { ui, calls } = harness(); ui.status = { ...running, backendState: 'Starting' };
  await ui.setVpn(true);
  assert.ok(!calls.includes('vpnStart'));
  assert.equal(model.isAuthenticated(ui.status), true);
  assert.match(ui.message, /重新连接/);
  ui.aboutToDisappear();
});

test('expired authentication and explicit logout still return to signed-out state', async () => {
  const { ui } = harness({ getStatus: async () => JSON.stringify(loggedOut) });
  ui.status = { ...running, backendState: 'Starting' };
  await ui.refreshData(true);
  assert.equal(model.isAuthenticated(ui.status), false);
  ui.status = { ...running, backendState: 'Stopped' };
  await ui.logout();
  assert.equal(model.isAuthenticated(ui.status), false);
  ui.aboutToDisappear();
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

test('silent refresh keeps controls enabled, notice and diagnostics unchanged; equal models keep identity', async () => {
  let release;
  let delayed = false;
  const { ui } = harness({ getStatus: async () => {
    if (delayed) await new Promise((resolve) => { release = resolve; });
    return JSON.stringify(running);
  } });
  await ui.refreshData();
  const status = ui.status, peers = ui.peers, vpn = ui.vpn;
  ui.page = 'detail'; ui.selectedPeer = peers[0]; ui.message = 'VPN 已开启';
  ui.progress = 'idle'; ui.output = 'manually inspected diagnostic'; ui.lastUpdated = 'unchanged timestamp';
  delayed = true;
  const pending = ui.refreshData(true);
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(ui.busy, false); assert.equal(ui.progress, 'idle');
  assert.equal(ui.message, 'VPN 已开启'); assert.ok(ui.refreshTask);
  const duplicate = ui.refreshData(true);
  release(); await Promise.all([pending, duplicate]);
  assert.equal(ui.status, status); assert.equal(ui.peers, peers); assert.equal(ui.vpn, vpn);
  assert.equal(ui.selectedPeer, peers[0]); assert.equal(ui.page, 'detail');
  assert.equal(ui.lastUpdated, 'unchanged timestamp');
  assert.equal(ui.output, 'manually inspected diagnostic'); assert.equal(ui.refreshTask, undefined);
  ui.aboutToDisappear();
});

test('silent refresh applies changed peers/detail and packet counters without a global loading state', async () => {
  const changed = { ...onlinePeer, hostName: 'renamed-host' };
  let nextPeers = [onlinePeer];
  const live = Object.assign(new sessionModel.VpnState(), { connected: true, state: 'connected', ipv4: '100.64.1.1' });
  const { ui } = harness({
    getVpnStatus: async () => JSON.stringify(live),
    onlinePeers: async () => JSON.stringify({ ok: true, peers: nextPeers })
  });
  await ui.refreshData(); ui.page = 'detail'; ui.selectedPeer = ui.peers[0];
  nextPeers = [changed]; live.rxPackets = 15;
  await ui.refreshData(true);
  assert.equal(ui.busy, false); assert.equal(ui.page, 'detail');
  assert.equal(ui.peers[0].hostName, 'renamed-host'); assert.equal(ui.selectedPeer, ui.peers[0]);
  assert.equal(ui.vpn.rxPackets, 15);
  ui.aboutToDisappear();
});

test('periodic VPN timer uses silent refresh and leaves the existing notice intact', async (t) => {
  t.mock.timers.enable({ apis: ['setTimeout', 'Date'], now: 1000 });
  const { ui } = harness(); ui.status = running;
  await ui.setVpn(true); const notice = ui.message;
  ui.output = 'last diagnostic';
  t.mock.timers.tick(5000);
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(ui.busy, false); assert.equal(ui.message, notice); assert.equal(ui.output, 'last diagnostic');
  assert.ok(ui.vpnTimer !== -1);
  ui.aboutToDisappear();
});

test('VPN handoff waits for an in-flight silent refresh before closing its backend', async () => {
  let release;
  let first = true;
  const { ui, calls } = harness({ getStatus: async () => {
    if (first) { first = false; await new Promise((resolve) => { release = resolve; }); }
    return JSON.stringify(running);
  } });
  ui.status = running;
  const refresh = ui.refreshData(true);
  await new Promise((resolve) => setImmediate(resolve));
  const switching = ui.setVpn(true);
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(ui.busy, true); assert.ok(!calls.includes('close'));
  release(); await Promise.all([refresh, switching]);
  assert.ok(calls.indexOf('close') > calls.findIndex((c) => Array.isArray(c) && c[0] === 'peers'));
  assert.equal(ui.vpn.connected, true); assert.equal(ui.busy, false);
  ui.aboutToDisappear();
});

test('silent polling reports real failures and does not rearm after unmount', async () => {
  let release;
  const { ui } = harness({ onlinePeers: async () => { throw new Error('peer API failed'); } });
  ui.peers = [onlinePeer];
  await ui.refreshData(true);
  assert.match(ui.message, /peer API failed/); assert.deepEqual(ui.peers, []); assert.equal(ui.busy, false);
  const late = harness({ getStatus: async () => {
    await new Promise((resolve) => { release = resolve; }); throw new Error('late failure');
  } }).ui;
  const pending = late.refreshData(true);
  await new Promise((resolve) => setImmediate(resolve));
  late.message = 'detached'; late.aboutToDisappear(); release(); await pending;
  assert.equal(late.message, 'detached'); assert.equal(late.vpnTimer, -1); assert.equal(late.refreshTask, undefined);
});

function windowHarness(t) {
  const previous = globalThis.AppStorage;
  const storage = new Map();
  globalThis.AppStorage = { setOrCreate: (key, value) => storage.set(key, value) };
  t.after(() => { globalThis.AppStorage = previous; });
  const types = { TYPE_SYSTEM: 0, TYPE_NAVIGATION_INDICATOR: 1, TYPE_CUTOUT: 2 };
  const areas = [
    { topRect: { height: 72 }, bottomRect: { height: 0 }, leftRect: { width: 0 }, rightRect: { width: 0 } },
    { topRect: { height: 0 }, bottomRect: { height: 48 }, leftRect: { width: 0 }, rightRect: { width: 0 } },
    { topRect: { height: 60 }, bottomRect: { height: 0 }, leftRect: { width: 0 }, rightRect: { width: 0 } }
  ];
  let callback;
  const calls = [];
  const mainWindow = {
    setWindowSystemBarProperties: async (props) => calls.push(['bars', props]),
    setWindowLayoutFullScreen: async (enabled) => {
      assert.equal(storage.get('tailscale.safeTop'), 24);
      assert.equal(storage.get('tailscale.safeBottom'), 16);
      calls.push(['fullscreen', enabled]);
    },
    getUIContext: () => ({ px2vp: (px) => px / 3 }),
    getWindowAvoidArea: (type) => areas[type],
    on: (event, handler) => { assert.equal(event, 'avoidAreaChange'); callback = handler; calls.push('subscribe'); },
    off: (event, handler) => { assert.equal(event, 'avoidAreaChange'); assert.equal(handler, callback); calls.push('unsubscribe'); }
  };
  const { WindowLayout } = compile(fs.readFileSync(path.join(root, 'entry/src/main/ets/entryability/WindowLayout.ets'), 'utf8'), 'window-layout.cjs', {
    '@kit.ArkUI': { window: { AvoidAreaType: types } }
  });
  return { layout: new WindowLayout(mainWindow), mainWindow, areas, storage, calls, notify: () => callback({}) };
}

test('edge-to-edge layout paints system bars, respects converted safe insets and updates on rotation', async (t) => {
  const { layout, areas, storage, calls, notify } = windowHarness(t);
  await layout.start();
  assert.equal(calls[0][1].statusBarColor, '#EAF4FF');
  assert.equal(calls[0][1].navigationBarColor, '#EEF6FC');
  assert.equal(calls[0][1].statusBarContentColor, '#142337');
  assert.ok(calls.some((c) => Array.isArray(c) && c[0] === 'fullscreen' && c[1] === true));
  areas[0].topRect.height = 0; areas[2].topRect.height = 0; areas[2].leftRect.width = 90;
  areas[1].bottomRect.height = 60;
  notify();
  assert.equal(storage.get('tailscale.safeTop'), 0); assert.equal(storage.get('tailscale.safeLeft'), 30);
  assert.equal(storage.get('tailscale.safeBottom'), 20);
  layout.stop(); layout.stop(); assert.equal(calls.filter((c) => c === 'unsubscribe').length, 1);
});

test('full-screen API failure leaves the avoid-area subscription removable', async (t) => {
  const { layout, mainWindow, calls, storage } = windowHarness(t);
  mainWindow.setWindowLayoutFullScreen = async () => { throw new Error('layout denied'); };
  await assert.rejects(layout.start(), /layout denied/);
  layout.stop(); assert.equal(calls.filter((c) => c === 'unsubscribe').length, 1);
  assert.equal(storage.get('tailscale.safeTop'), 0); assert.equal(storage.get('tailscale.safeBottom'), 0);
});

test('destroying the stage during pending window setup prevents a late subscription', async (t) => {
  const { layout, mainWindow, calls } = windowHarness(t);
  let release;
  mainWindow.setWindowSystemBarProperties = () => new Promise((resolve) => { release = resolve; });
  const pending = layout.start(); layout.stop(); release(); await pending;
  assert.ok(!calls.includes('subscribe'));
  assert.ok(!calls.some((c) => Array.isArray(c) && c[0] === 'fullscreen'));
});
