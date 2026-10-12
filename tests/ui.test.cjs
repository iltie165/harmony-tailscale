'use strict';
const { test, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const Module = require('node:module');
const path = require('node:path');
const ts = require(process.env.TYPESCRIPT_MODULE);
const root = path.resolve(__dirname, '..');
const activeViews = new Set();
afterEach(() => { for (const ui of activeViews) { ui.aboutToDisappear(); ui.destroyRuntime(); } activeViews.clear(); });
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
function harness(overrides = {}, vpnOverrides = {}, probeReportOverrides = {}, sessionOverrides = {}, files = new Map()) {
  const calls = [];
  let sessionLive = false;
  let accountAlive = false;
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
    getVpnStatus: async () => JSON.stringify(Object.assign(new sessionModel.VpnState(), {coreAlive:accountAlive||serviceAlive,coreId:serviceAlive?'1-2':accountAlive?'5-6':'',coreHost:serviceAlive?'vpn':accountAlive?'account':''}, sessionLive ? {
      connected: true, state: 'connected', ipv4: '100.64.1.1', txPackets: 1, rxPackets: 2
    } : {})),
    configurePlatform: async () => '{"ok":true}',
    startAccount: async () => { calls.push('accountStart');accountAlive=true;return '{"ok":true}'; },
    releaseAccount: async () => { calls.push('releaseAccount');accountAlive=false;return '{"ok":true}'; },
    networkChanged: async () => '{"ok":true}',
    start: async () => { calls.push('start'); return JSON.stringify({ ok: true, state: 'started' }); },
    getStatus: async () => { calls.push('status'); return JSON.stringify(running); },
    onlinePeers: async (filter) => { calls.push(['peers', filter]); return JSON.stringify({ ok: true, peers: [onlinePeer] }); },
    login: async () => { calls.push('login'); return JSON.stringify({ ...loggedOut, authUrl: 'https://login.tailscale.com/a/private' }); },
    logout: async () => JSON.stringify(loggedOut),
    close: async () => { calls.push('close'); return JSON.stringify({ ok: true, state: 'closed' }); },
    ...overrides
  };
  const originalAccountStart=native.startAccount;
  native.startAccount=async(...args)=>{
    const raw=await originalAccountStart(...args);
    if(JSON.parse(raw).ok){accountAlive=true;}
    return raw;
  };
  const emitter = { on() {}, off() {}, emit() {} };
  const preview = compile(fs.readFileSync(path.join(root, 'entry/src/main/ets/pages/SessionPreview.ets'), 'utf8'), 'preview.cjs', {
    './ClientModel': model, '@kit.CoreFileKit': { fileIo: {
      OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4 },
      accessSync: (p) => files.has(p),
      readTextSync: (p) => files.get(p),
      openSync: (p) => ({ fd: p }),
      writeSync: (p, text) => files.set(p, text),
      closeSync() {},
      renameSync: (from, to) => { files.set(to, files.get(from)); files.delete(from); }
    } }
  });
  const recovery = compile(fs.readFileSync(path.join(root, 'entry/src/main/ets/vpn/VpnRecoveryModel.ets'), 'utf8'), 'recovery.cjs');
  const serviceModel = compile(fs.readFileSync(path.join(root, 'entry/src/main/ets/vpn/NetworkServiceModel.ets'), 'utf8'), 'service-model.cjs', {
    './VpnSessionModel': sessionModel, '../pages/ClientModel': model, './VpnRecoveryModel': recovery
  });
  const serviceClient = compile(fs.readFileSync(path.join(root, 'entry/src/main/ets/vpn/NetworkServiceClient.ets'), 'utf8'), 'service-client.cjs', {
    './NetworkServiceModel': serviceModel, './VpnSessionModel': sessionModel, '../pages/ClientModel': model
  });
  let serviceAlive = false,extensionPresent=false;
  let serviceSnapshot = Object.assign(new serviceModel.ServiceSnapshot(), {
    ownerId: '1-2', coreId: '1-2', coreAlive: true, serviceReady: true, phase: 'idle', timestamp: Date.now()
  });
  const accountModule=compile(fs.readFileSync(path.join(root,'entry/src/main/ets/pages/AccountSessionPlatform.ets'),'utf8'),'account-platform.cjs',{
    '@kit.NetworkKit':{connection:{createNetConnection:()=>({register:cb=>cb(),unregister:cb=>cb(),on(){}})}},
    '@kit.BasicServicesKit':{},'libtailscale_napi.so':{default:native},'./ClientModel':model,
    './PlatformInfo':{configurePlatformInfo:async()=>{}},'../vpn/NetworkServiceClient':serviceClient,'../vpn/VpnSessionModel':sessionModel
  });
  class PlatformNetworkClient {
    update() {}
    read() { if (!extensionPresent) return undefined; serviceSnapshot.timestamp=Date.now(); return serviceSnapshot; }
    beginHandoff() { accountModule.getAccountSession().beginHandoff(); }
    finishHandoff() { accountModule.getAccountSession().finishHandoff(); }
    releaseAccount() { return accountModule.getAccountSession().release(); }
    async start(id) {
      calls.push('serviceStart');if(sessionOverrides.authorize){await sessionOverrides.authorize();}
      extensionPresent=true;
      serviceSnapshot=Object.assign(new serviceModel.ServiceSnapshot(),{ownerId:id,phase:'handoff_wait',timestamp:Date.now()});
    }
    async stop() { calls.push('serviceStop');serviceAlive=false;extensionPresent=false; }
    async connect() { return native.start(); }
    async closeProxy() { calls.push('proxyClose');return '{"ok":true}'; }
    async status() {
      const v = JSON.parse(await native.getVpnStatus());
      return JSON.stringify({ ...v, coreAlive: serviceAlive, coreId: '1-2', attached: v.connected });
    }
    command(c) {
      if(c.handoff){calls.push('handoff');serviceAlive=true;Object.assign(serviceSnapshot,{coreId:'1-2',coreAlive:true,serviceReady:true,phase:'idle',timestamp:Date.now()});return;}
      serviceSnapshot.commandId=c.commandId;serviceSnapshot.desiredEnabled=c.enabled;
      if (c.shutdown) {
        calls.push('shutdownCommand');sessionLive=false;
        Object.assign(serviceSnapshot,{phase:'stopped',connected:false,state:'disconnected',serviceReady:false,coreAlive:false,detached:true,destroyed:true});
        return;
      }
      calls.push(['serviceCommand',c.enabled]);
      if (!c.enabled) {
        calls.push('detachInterface'); calls.push('destroyInterface'); sessionLive=false;
        Object.assign(serviceSnapshot,{phase:'idle',state:'disconnected',connected:false,detached:true,destroyed:true,attached:false,ipv4:''});
        if(sessionOverrides.cleanup) {
          const old=sessionOverrides.cleanup;
          Object.assign(serviceSnapshot,{phase:old.coreClosed===false||old.destroyed===false?'cleanup_pending':'idle',ok:old.ok!==false,
            detached:old.coreClosed!==false,destroyed:old.destroyed!==false,error:old.error||'',state:old.ok===false?'error':'disconnected'});
        }
        return;
      }
      serviceSnapshot.phase='waiting_core';
      Promise.resolve().then(async()=>{
        try {
          const status=model.readControl(await native.getStatus());
          if(!model.isAuthenticated(status)) throw new Error('账号需要重新认证，请先登录');
          const ip=status.tailscaleIPs?.find(sessionModel.tailnetIPv4);
          if(!ip) throw new Error('未取得本机 Tailnet IPv4');
          if(status.backendState!=='Running') throw new Error('核心尚未就绪');
          if(!serviceSnapshot.desiredEnabled) return;
          const session=new PlatformSessionRequest('/private',c.commandId,ip);
          await session.start();
          Object.assign(serviceSnapshot,{phase:'connected',state:'connected',connected:true,created:true,
            detached:false,destroyed:false,processProtected:true,attached:true,ipv4:ip,txPackets:1,rxPackets:2});
        }catch(e){ Object.assign(serviceSnapshot,{phase:'error',state:'error',ok:false,error:String(e),connected:false,detached:true,destroyed:true}); }
      });
    }
    delay() { return new Promise(resolve=>setImmediate(resolve)); }
  }
  class NetworkServiceStore {
    intent() { const raw=files.get('/private/vpn-intent.json');return raw?recovery.readVpnIntent(raw):undefined; }
    saveIntent(value) { files.set('/private/vpn-intent.json',JSON.stringify(value)); }
  }
  const recoveryPlatform=compile(fs.readFileSync(path.join(root,'entry/src/main/ets/vpn/VpnRecoveryPlatform.ets'),'utf8'),'recovery-platform.cjs',{
    'libtailscale_napi.so':{default:native},'../pages/ClientModel':model,'./NetworkServiceClient':serviceClient,
    './NetworkClientPlatform':{PlatformNetworkClient},'./NetworkServiceStore':{NetworkServiceStore},'./NetworkServiceModel':serviceModel,
    './VpnRecoveryModel':recovery,'./VpnSessionModel':sessionModel,'./NetworkEnvironment':{inspectNetworks:async()=>({online:true,ownVpn:sessionLive,otherVpn:false})}
  });
  const source=fs.readFileSync(path.join(root, 'entry/src/main/ets/pages/ClientController.ets'), 'utf8');
  const { ClientController: Index } = compile(source, 'controller.cjs', {
    '@kit.AbilityKit': {}, '@kit.BasicServicesKit': { emitter },
    '@kit.CoreFileKit': { fileIo: { accessSync: () => true } },
    '@kit.PerformanceAnalysisKit': { hilog: { info() {}, warn() {} } },
    'libtailscale_napi.so': { default: native }, './ClientModel': model,
    './SessionPreview': preview,
    './AccountSessionPlatform':accountModule,
    './PlatformInfo': { readPlatformInfo: () => ({os:'openharmony',osVersion:'test',deviceModel:'test-phone'}) },
    '../vpn/VpnProbeClient': vpnClient, '../vpn/VpnProbePlatform': platform,
    '../vpn/VpnSessionModel': sessionModel, '../vpn/VpnSessionClient': sessionClient,
    '../vpn/NetworkServiceClient': serviceClient,
    '../vpn/NetworkServiceModel':serviceModel,
    '../vpn/NetworkClientPlatform': { PlatformNetworkClient },
    '../vpn/VpnRecoveryModel':recovery, '../vpn/VpnRecoveryPlatform':recoveryPlatform
  });
  const ui = new Index();
  // Existing interaction cases start after the startup gate. Startup cases
  // explicitly invoke restoreSession(), which resets the gate.
  ui.startupPhase = 'ready';
  activeViews.add(ui);
  ui.mounted = true;
  ui.dataDir = '/private/tailscale';
  ui.appContext = {
    filesDir: '/private',
    openLink: async (url) => { calls.push(['browser', url]); },
    startAbility: async () => { calls.push('fallback'); }
  };
  return { ui, calls, probeCalls, files, preview, native, accountModule };
}

test('a current native map releases startup and enables VPN while account refresh is pending',async t=>{
  t.mock.timers.enable({apis:['setTimeout','Date'],now:1000});
  let release;
  const {ui}=harness({getStatus:()=>new Promise(resolve=>{release=resolve;}),getVpnStatus:async()=>JSON.stringify({
    ...new sessionModel.VpnState(),coreAlive:true,coreId:'5-6',coreHost:'account',networkMapReady:true,assignedIPv4:'100.64.1.1'
  })});
  ui.previewAccount=running;
  const opening=ui.restoreSession();
  for(let i=0;i<20&&!release;i++)await new Promise(resolve=>setImmediate(resolve));
  assert.ok(release);assert.equal(ui.busy,false);assert.equal(ui.startupBlocking(),false);
  assert.equal(ui.vpnToggleEnabled(),true);assert.match(ui.connectionLabel(),/VPN 未开启/);
  release(JSON.stringify({...running,backendState:'Starting',health:['Tailscale is starting. Please wait.','DNS error']}));
  await opening;
  assert.equal(ui.peersStale,false);assert.equal(ui.peers.length,1);
  assert.deepEqual(ui.displayHealth(),['网络配置已就绪，正在建立直连或中继通路。','DNS error']);
  t.mock.timers.tick(30001);assert.equal(ui.startupBlocking(),false);assert.equal(ui.startupPhase,'ready');
});

test('main VPN toggle commands a stable service and OFF retains core/account without SDK stop', async () => {
  const { ui, calls } = harness(); ui.status = running;
  await ui.setVpn(true);
  assert.ok(calls.includes('serviceStart')); assert.ok(!calls.includes('close')); assert.ok(calls.some(c=>Array.isArray(c)&&c[0]==='serviceCommand'&&c[1]===true));
  assert.equal(ui.vpn.connected, true); assert.equal(ui.vpn.rxPackets, 2);
  assert.equal(ui.vpnNeedsCleanup, false); assert.equal(ui.busy, false);
  assert.ok(ui.vpnTimer !== -1);
  await ui.setVpn(false);
  assert.equal(ui.vpn.connected, false); assert.equal(ui.vpnNeedsCleanup, false);
  if(ui.refreshTask)await ui.refreshTask;assert.equal(ui.status.loggedIn, true); assert.equal(ui.peers.length, 1);
  assert.ok(calls.includes('detachInterface')); assert.ok(calls.includes('destroyInterface')); assert.ok(!calls.includes('serviceStop')); assert.ok(!calls.includes('close'));
  assert.match(ui.vpnMessage, /账号已保留/); ui.aboutToDisappear();
});

test('local account startup allows a connect request before live network readiness', async () => {
  let state={...running,backendState:'Starting'};
  const {ui,calls}=harness({getStatus:async()=>JSON.stringify(state),onlinePeers:async()=>{throw new Error('peer sync unavailable');}});
  await ui.restoreSession();
  assert.equal(ui.startupBlocking(),false);assert.equal(ui.vpnToggleEnabled(),true);assert.equal(ui.vpnWanted(),false);
  assert.ok(!calls.some(c=>Array.isArray(c)&&c[0]==='serviceCommand'&&c[1]));
  state={...running,tailscaleIPs:['fd7a:115c:a1e0::1']};await ui.refreshData(true);
  assert.equal(ui.vpnToggleEnabled(),true);assert.equal(ui.startupBlocking(),false);
  state=running;await ui.refreshData(true);
  assert.equal(ui.startupBlocking(),false);assert.equal(ui.vpnToggleEnabled(),true);
  assert.match(ui.peersError,/peer sync unavailable/);assert.ok(!calls.includes('login'));
});
test('local bootstrap timeout offers diagnostics and late bootstrap releases the gate', async t=>{
  t.mock.timers.enable({apis:['setTimeout','Date'],now:1000});
  let release;
  const {ui}=harness();
  ui.ensureAccount=()=>new Promise(resolve=>{release=resolve;});
  const opening=ui.restoreSession();t.mock.timers.tick(30001);await new Promise(resolve=>setImmediate(resolve));
  assert.equal(ui.startupPhase,'failed');assert.match(ui.startupError,/30 秒/);assert.equal(ui.startupBlocking(),false);
  ui.dismissStartup();assert.equal(ui.startupBlocking(),false);assert.equal(ui.vpnToggleEnabled(),false);
  await ui.retryStartup();assert.equal(ui.busy,false);
  release();await opening;assert.equal(ui.startupPhase,'ready');assert.equal(ui.startupError,'');
});
test('diagnostic service restart releases a failed local startup gate',async()=>{
  const {ui}=harness();ui.startupPhase='failed';ui.startupError='connection refused';ui.message='恢复状态失败';
  await ui.diagnostic('start');
  assert.equal(ui.startupPhase,'ready');assert.equal(ui.startupError,'');
  assert.equal(ui.startupBlocking(),false);assert.match(ui.output,/网络服务已就绪/);
});

test('expired credentials release startup overlay and invalidate cached login; machine approval is explicit',async()=>{
  for(const backendState of ['NeedsLogin','NeedsMachineAuth']) {
    const {ui}=harness({getStatus:async()=>JSON.stringify({...loggedOut,backendState})});
    ui.previewAccount=running;
    await ui.restoreSession();assert.equal(ui.startupBlocking(),false);assert.equal(ui.hasAccount(),false);
    assert.equal(ui.vpnToggleEnabled(),false);
    if(backendState==='NeedsMachineAuth')assert.match(ui.message,/管理员批准/);
  }
});
test('startup query failures do not leave an endless spinner or authorize VPN using the cache',async()=>{
  const {ui}=harness({getStatus:async()=>{throw new Error('control unavailable');}});
  ui.previewAccount=running;await ui.restoreSession();
  assert.equal(ui.startupPhase,'ready');assert.equal(ui.startupBlocking(),false);assert.equal(ui.busy,false);assert.match(ui.peersError,/control unavailable/);
  assert.equal(ui.vpnToggleEnabled(),true);assert.equal(ui.hasAccount(),true);
});
test('control reconnection after readiness never restores a global overlay and OFF stays available',async()=>{
  let restarting=false;
  const {ui}=harness({getStatus:async()=>JSON.stringify({...running,backendState:restarting?'Starting':'Running'})});
  await ui.restoreSession();await ui.setVpn(true);restarting=true;await ui.refreshData(true);
  assert.equal(ui.startupBlocking(),false);assert.equal(ui.vpnToggleEnabled(),true);
  await ui.setVpn(false);assert.equal(ui.vpnWanted(),false);
});

test('background and page disposal retain runtime recovery; explicit OFF cancels and persists it',async()=>{
  const {ui,calls,files}=harness();ui.status=running;await ui.setVpn(true);
  assert.equal(ui.vpnWanted(),true);assert.equal(JSON.parse(files.get('/private/vpn-intent.json')).enabled,true);
  ui.backgroundCallback({});ui.aboutToDisappear();
  assert.notEqual(ui.supervisor.timer,-1);calls.length=0;await ui.supervisor.check();
  assert.ok(!calls.some(c=>Array.isArray(c)&&c[0]==='peers'));assert.equal(ui.vpnWanted(),true);
  ui.mounted=true;await ui.setVpn(false);
  assert.equal(JSON.parse(files.get('/private/vpn-intent.json')).enabled,false);assert.equal(ui.supervisor.timer,-1);
});

test('logout clears the persistent ON even after the current interface has already disappeared',async()=>{
  const {ui,files}=harness();ui.status=running;await ui.setVpn(true);
  ui.vpn.connected=false;ui.vpn.attached=false;ui.vpn.state='disconnected';
  await ui.logout();assert.equal(JSON.parse(files.get('/private/vpn-intent.json')).enabled,false);
  assert.equal(ui.vpnWanted(),false);assert.equal(ui.hasAccount(),false);
});

test('OFF revokes automatic recovery before an unrelated peer refresh completes',async()=>{
  const {ui,files}=harness();ui.status=running;await ui.setVpn(true);
  let release;ui.refreshTask=new Promise(resolve=>{release=resolve;});
  const stopping=ui.setVpn(false);await new Promise(resolve=>setImmediate(resolve));
  assert.equal(JSON.parse(files.get('/private/vpn-intent.json')).enabled,false);
  assert.equal(ui.vpnWanted(),false);assert.equal(ui.vpn.connected,false);
  release();await stopping;
});

test('accepted VPN intent outlives a page observer and releases UI mutation flags on completion',async()=>{
  let release;
  const {ui,calls}=harness({}, {}, {}, {start:()=>new Promise(resolve=>{release=resolve;})});ui.status=running;
  const pending=ui.setVpn(true);
  for(let i=0;i<20&&!release;i++)await new Promise(resolve=>setImmediate(resolve));
  assert.ok(release);ui.aboutToDisappear();release();await pending;
  assert.equal(ui.busy,false);assert.equal(ui.vpnChanging,false);
  assert.ok(!calls.includes('detachInterface'));assert.ok(!calls.includes('close'));
});

test('restoration keeps SDK cleanup uncertainty even when native attachment is already detached',async()=>{
  const {ui}=harness();await ui.restoreSession();await ui.setVpn(true);await ui.setVpn(false);
  Object.assign(ui.networkPort.read(),{phase:'cleanup_pending',ok:false,state:'error',error:'destroy failed',created:true,destroyed:false,
    connected:false,attached:false,detached:true,descriptorClosed:true});
  await assert.rejects(ui.loadData(true),/destroy failed/);
  assert.equal(ui.vpnNeedsCleanup,true);assert.equal(ui.vpn.connected,false);assert.equal(ui.hasAccount(),true);
});
test('VPN toggle requires authenticated assigned IPv4 and suppresses duplicate busy actions', async () => {
  for (const status of [loggedOut, { ...running, tailscaleIPs: ['fd7a::1'] }]) {
    const { ui, calls } = harness({ getStatus: async () => JSON.stringify(status) }); ui.status = status;
    await ui.setVpn(true); assert.equal(ui.vpn.connected, false); assert.ok(!calls.includes('vpnStart'));
    assert.match(ui.vpnMessage, /登录|IPv4/);
  }
  const { ui, calls } = harness(); ui.status = running; ui.busy = true;
  await ui.setVpn(true); assert.deepEqual(calls, []);
});
test('failed OFF leaves shutdown uncertain and retryable; it does not resume another core', async () => {
  const { ui, calls } = harness({}, {}, {}, { cleanup: { ok: false, stage: 'failed', state: 'error', coreClosed: false, error: 'core shutdown failed' } });
  ui.status = running; await ui.setVpn(true); calls.length = 0;
  await ui.setVpn(false);
  assert.equal(ui.vpnNeedsCleanup, true); assert.equal(ui.vpn.ok, false);
  assert.match(ui.vpnMessage, /关闭状态待确认/); assert.ok(!calls.includes('start')); assert.ok(!calls.includes('close'));
  ui.aboutToDisappear();
});

test('peer query failure after confirmed VPN startup does not mark VPN failed or require cleanup', async () => {
  const { ui, calls } = harness({ onlinePeers: async () => { throw new Error('peer query timed out'); } });
  ui.status = running; await ui.setVpn(true);
  assert.equal(ui.vpnNeedsCleanup, false); assert.equal(ui.vpn.connected, true);
  assert.match(ui.vpnMessage, /VPN 已开启/);if(ui.refreshTask)await ui.refreshTask.catch(()=>{});assert.match(ui.peersError,/peer query timed out/);
  assert.equal(calls.filter((c) => c === 'close').length, 0);
  assert.equal(calls.filter((c) => c === 'serviceStart').length, 1);
  assert.ok(!calls.includes('vpnStop')); ui.aboutToDisappear();
});
test('VPN rejects conflicting diagnostic/probe controls and unmount does not turn it off', async () => {
  const { ui, calls } = harness(); ui.status = running; await ui.setVpn(true);
  calls.length = 0; await ui.diagnostic('close'); assert.match(ui.output, /主界面开关/);
  ui.canProbe(); assert.match(ui.message, /先停止网络服务/);
  ui.aboutToDisappear(); assert.deepEqual(calls, []); assert.equal(ui.vpn.connected, true);
});

test('temporarily reconnecting VPN remains ON and can still be explicitly disconnected', async () => {
  const { ui, calls } = harness(); ui.status = running; await ui.setVpn(true);
  ui.vpn.connected = false; ui.vpn.state = 'connecting';
  assert.equal(ui.vpnRunning(), true);
  ui.canProbe(); assert.match(ui.message, /先停止/);
  await ui.setVpn(false); assert.ok(calls.includes('detachInterface')); assert.equal(ui.vpnRunning(), false);
  ui.aboutToDisappear();
});
test('logging out while VPN is active confirms shutdown before deleting login state', async () => {
  const { ui, calls } = harness({ logout: async () => { calls.push('logout'); return JSON.stringify(loggedOut); } });
  ui.status = running; await ui.setVpn(true); await ui.logout();
  assert.ok(calls.indexOf('detachInterface') < calls.indexOf('logout'));
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
  assert.ok(calls.includes('accountStart'));assert.ok(!calls.includes('serviceStart'));assert.ok(!calls.includes('proxyClose'));assert.ok(!calls.includes('login'));
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
test('peer refresh failure retains labelled historical devices and preserves backend error', async () => {
  const { ui } = harness({ onlinePeers: async () => JSON.stringify({ ok: false, error: 'group unsupported' }) });
  ui.peers = [onlinePeer];
  ui.lastUpdated = 'yesterday';
  await ui.refreshData();
  assert.equal(ui.peers.length, 1);
  assert.equal(ui.peersStale, true);
  assert.equal(ui.lastUpdated, 'yesterday');
  assert.match(ui.peersError, /group unsupported/);
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
  assert.equal(calls.filter((c) => c === 'accountStart').length, 1);
});
test('navigation back and close distinguish stopping core from deleting account state', async () => {
  const { ui } = harness();
  ui.page = 'diagnostics';
  assert.equal(ui.onBackPress(), true);
  assert.equal(ui.page, 'settings');
  assert.equal(ui.onBackPress(), true);
  assert.equal(ui.page, 'main');
  assert.equal(ui.onBackPress(), false);
  await ui.restoreSession(); ui.peers = [onlinePeer];
  await ui.diagnostic('close');
  assert.equal(model.isAuthenticated(ui.status), false);
  assert.equal(ui.hasAccount(), true); assert.equal(ui.corePaused, true);
  if(ui.refreshTask)await ui.refreshTask;assert.equal(ui.peers.length, 1); assert.equal(ui.peersStale, true);
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
  assert.equal(ui.startupBlocking(), false); assert.equal(ui.vpnToggleEnabled(), true);
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
  assert.equal(ui.startupBlocking(), false); assert.equal(ui.vpnToggleEnabled(), true);
  assert.equal(ui.busy, false);
  assert.notEqual(ui.vpnTimer, -1);
  ui.aboutToDisappear();
});

test('VPN OFF preserves account during network reconnection, without core recreation or logout', async () => {
  let restarting = false;
  const { ui, calls } = harness({
    getStatus: async () => JSON.stringify({ ...running, backendState: restarting ? 'Starting' : 'Running' }),
    logout: async () => { throw new Error('OFF must never log out'); }
  });
  ui.status = running;
  await ui.setVpn(true);if(ui.refreshTask)await ui.refreshTask;
  restarting = true;
  await ui.setVpn(false);
  assert.equal(ui.vpn.connected, false);
  assert.equal(model.isAuthenticated(ui.status), true);
  if(ui.refreshTask)await ui.refreshTask;assert.equal(ui.peers.length, 1); assert.equal(ui.peersStale, true);
  assert.equal(ui.pollTimer, -1);
  assert.match(ui.vpnMessage, /账号已保留/);
  assert.ok(!calls.includes('login'));
  assert.ok(!calls.some((c) => Array.isArray(c) && c[0] === 'browser'));
  restarting = false;
  await ui.refreshData(true);
  assert.equal(ui.peers.length, 1);
  assert.equal(ui.pollTimer, -1);
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

test('VPN command does not wait for in-flight account refresh and never closes the backend', async () => {
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
  assert.equal(ui.busy, false);assert.equal(ui.vpnChanging,true); assert.ok(!calls.includes('close'));
  for(let i=0;i<200&&!ui.vpn.connected;i++)await new Promise(resolve=>setImmediate(resolve));
  assert.equal(ui.vpn.connected,true); // Old status query is still unresolved.
  release(); await Promise.all([refresh, switching]);
  assert.ok(calls.some(c=>Array.isArray(c)&&c[0]==='serviceCommand')); assert.ok(!calls.includes('close'));
  assert.equal(ui.vpn.connected, true); assert.equal(ui.busy, false);
  ui.aboutToDisappear();
});

test('silent polling reports real failures and does not rearm after unmount', async () => {
  let release;
  const { ui } = harness({ onlinePeers: async () => { throw new Error('peer API failed'); } });
  ui.peers = [onlinePeer];
  await ui.refreshData(true);
  assert.match(ui.peersError, /peer API failed/); assert.deepEqual(ui.peers, [onlinePeer]);
  assert.equal(ui.peersStale, true); assert.equal(ui.busy, false);
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
    setWindowBackgroundColor: (color) => calls.push(['background', color]),
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
  assert.deepEqual(calls[0], ['background', '#EEF6FC']);
  assert.equal(calls[1][1].statusBarColor, '#EAF4FF');
  assert.equal(calls[1][1].navigationBarColor, '#EEF6FC');
  assert.equal(calls[1][1].statusBarContentColor, '#142337');
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
  assert.deepEqual(calls[0], ['background', '#EEF6FC']);
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

test('display cache renders an account before native startup without claiming authentication or VPN readiness', async () => {
  let release;
  const files = new Map();
  const setup = harness({}, {}, {}, {}, files);
  new setup.preview.SessionPreviewStore('/private').write(setup.preview.previewOf(running, [onlinePeer], 'last session'));
  const { ui, calls } = harness({ startAccount: () => new Promise((resolve) => { release = resolve; }) }, {}, {}, {}, files);
  const opening = ui.restoreSession();
  assert.equal(ui.restoringSession, true); assert.equal(ui.hasAccount(), true);
  assert.equal(ui.startupBlocking(), false); assert.equal(ui.vpnToggleEnabled(), true);
  assert.equal(model.isAuthenticated(ui.status), false); assert.equal(ui.vpn.connected, false);
  assert.deepEqual(JSON.parse(JSON.stringify(ui.peers)), [onlinePeer]); assert.equal(ui.peersStale, true);
  assert.equal(ui.lastUpdated, 'last session'); assert.ok(!calls.includes('status')); await new Promise(resolve=>setImmediate(resolve));
  assert.match(ui.connectionLabel(), /已保存账号/);
  release(JSON.stringify({ ok: true, state: 'started' })); await opening;
  assert.equal(model.isAuthenticated(ui.status), true); assert.equal(ui.peersStale, false);
});

test('offline core queries preserve cached display; explicit NeedsLogin invalidates it on disk', async () => {
  const files = new Map(); const setup = harness({}, {}, {}, {}, files);
  new setup.preview.SessionPreviewStore('/private').write(setup.preview.previewOf(running, [onlinePeer], 'saved'));
  let offline = true;
  const { ui } = harness({ getStatus: async () => {
    if (offline) throw new Error('network unavailable'); return JSON.stringify(loggedOut);
  } }, {}, {}, {}, files);
  await ui.restoreSession();
  assert.equal(ui.hasAccount(), true); assert.equal(ui.peersStale, true); assert.equal(ui.peers.length, 1);
  assert.match(ui.peersError, /network unavailable/); assert.equal(model.isAuthenticated(ui.status), false);
  offline = false; await ui.refreshData(true);
  assert.equal(ui.hasAccount(), false); assert.deepEqual(ui.peers, []);
  assert.equal(new setup.preview.SessionPreviewStore('/private').read(), undefined);
});

test('display cache is whitelisted and ignores injected credentials, auth flags and VPN state', () => {
  const { preview } = harness();
  const dirty = { ...running, authUrl: 'https://login.tailscale.com/a/secret', privateKey: 'private-secret',
    connected: true, debugLogs: ['secret-log'], self: { ...running.self, nodeKey: 'node-secret' } };
  const raw = JSON.stringify({ version: 1, account: dirty, peers: [{ ...onlinePeer, secret: 'peer-secret' }], updatedAt: 'saved' });
  const safe = preview.readPreview(raw);
  assert.equal(model.isAuthenticated(safe.account), false);
  const text = JSON.stringify(safe); assert.ok(!text.includes('secret'));
  assert.ok(!text.includes('authUrl')); assert.ok(!text.includes('connected')); assert.ok(!text.includes('loggedIn'));
  for (const bad of ['{}', 'not-json', JSON.stringify({ version: 1, account: running, peers: null, updatedAt: 'x' }),
    JSON.stringify({ version: 1, account: running, peers: [{ id: 9, online: true }], updatedAt: 'x' })]) {
    assert.throws(() => preview.readPreview(bad));
  }
});

test('a corrupted cache does not prevent live restoration; a successful logout leaves no saved account', async () => {
  const files = new Map([['/private/tailscale-display.json', '{broken']]);
  const { ui, preview } = harness({}, {}, {}, {}, files);
  await ui.restoreSession(); assert.equal(ui.hasAccount(), true);
  assert.ok(new preview.SessionPreviewStore('/private').read());
  await ui.logout(); assert.equal(ui.hasAccount(), false);
  assert.equal(new preview.SessionPreviewStore('/private').read(), undefined);
  const reopened = harness({ getStatus: async () => JSON.stringify(loggedOut) }, {}, {}, {}, files).ui;
  await reopened.restoreSession(); assert.equal(reopened.hasAccount(), false);
});

test('stored account cannot authorize VPN after live authentication expires', async () => {
  const { ui, calls, preview } = harness({ getStatus: async () => JSON.stringify(loggedOut) });
  ui.previewAccount = preview.previewOf(running, [], '').account;
  await ui.setVpn(true);
  assert.ok(!calls.includes('vpnStart')); assert.ok(!calls.includes('close'));
  assert.equal(ui.hasAccount(), false); assert.match(ui.vpnMessage, /重新认证/);
});

test('VPN OFF live accounts continue quiet foreground synchronization; background stops timers', async (t) => {
  t.mock.timers.enable({ apis: ['setTimeout', 'Date'], now: 1000 });
  const { ui, calls } = harness(); await ui.restoreSession(); calls.length = 0;
  assert.equal(ui.vpn.connected, false); assert.notEqual(ui.vpnTimer, -1);
  t.mock.timers.tick(5000); await new Promise((resolve) => setImmediate(resolve));
  assert.ok(calls.some((c) => Array.isArray(c) && c[0] === 'peers')); assert.equal(ui.busy, false);
  ui.backgroundCallback({}); assert.equal(ui.vpnTimer, -1); assert.equal(ui.pollTimer, -1);
  calls.length = 0; t.mock.timers.tick(15000); assert.deepEqual(calls, []);
  ui.foregroundCallback({}); await new Promise((resolve) => setImmediate(resolve));
  assert.notEqual(ui.vpnTimer, -1);
});

test('temporary reconnection retains details as historical data and restores freshness after recovery', async () => {
  let reconnecting = false;
  const { ui } = harness({ getStatus: async () => JSON.stringify({ ...running, backendState: reconnecting ? 'Starting' : 'Running' }) });
  await ui.restoreSession(); ui.page = 'detail'; ui.selectedPeer = ui.peers[0];
  const peers = ui.peers, selected = ui.selectedPeer, updated = ui.lastUpdated;
  reconnecting = true; await ui.refreshData(true);
  assert.equal(ui.peers, peers); assert.equal(ui.selectedPeer, selected); assert.equal(ui.lastUpdated, updated);
  assert.equal(ui.peersStale, true); assert.equal(ui.page, 'detail');
  reconnecting = false; await ui.refreshData(true); assert.equal(ui.peersStale, false);
});

test('diagnostic pause preserves display and prevents auto polling until explicitly resumed', async () => {
  const { ui } = harness(); await ui.restoreSession();
  await ui.diagnostic('close'); assert.equal(ui.hasAccount(), true); assert.equal(ui.corePaused, true);
  assert.equal(ui.vpnTimer, -1); assert.match(ui.connectionLabel(), /已暂停/);
  await ui.diagnostic('start');if(ui.refreshTask)await ui.refreshTask;assert.equal(ui.corePaused, false); assert.equal(ui.peersStale, false);
});

test('account or Tailnet changes clear the previous account devices before querying the new list', async () => {
  const { ui } = harness(); await ui.restoreSession(); ui.selectedPeer = ui.peers[0];
  ui.applyStatus({ ...running, tailnet: { magicDNSSuffix: 'other.ts.net' } });
  assert.equal(ui.peers.length, 0); assert.equal(ui.selectedPeer, undefined); assert.equal(ui.peersStale, true);
});

test('fresh successful query of an empty list is distinct from stale query failure', async () => {
  const { ui } = harness({ onlinePeers: async () => JSON.stringify({ ok: true, peers: [] }) });
  ui.peers = [onlinePeer]; await ui.restoreSession();
  assert.equal(ui.peers.length, 0); assert.equal(ui.peersStale, false); assert.ok(ui.lastUpdated);
});

test('a late startup failure after unmount does not change cached account display or notices', async () => {
  let rejectStart; const files = new Map(); const setup = harness({}, {}, {}, {}, files);
  new setup.preview.SessionPreviewStore('/private').write(setup.preview.previewOf(running, [onlinePeer], 'saved'));
  const { ui } = harness({ startAccount: () => new Promise((_resolve, reject) => { rejectStart = reject; }) }, {}, {}, {}, files);
  const opening = ui.restoreSession(); await new Promise(resolve=>setImmediate(resolve)); ui.message = 'detached'; ui.aboutToDisappear();
  rejectStart(new Error('late startup error')); await opening;
  assert.equal(ui.message, 'detached'); assert.equal(ui.hasAccount(), true); assert.equal(ui.pollTimer, -1);
});

test('cache persistence failures cannot turn a working account or VPN into a connection error', async () => {
  const { ui } = harness(); await ui.restoreSession();
  ui.previewStore.write = () => { throw new Error('disk full'); }; ui.persistedPreview = '';
  await ui.setVpn(true); assert.equal(ui.vpn.connected, true); assert.equal(ui.vpnNeedsCleanup, false);
  assert.equal(model.isAuthenticated(ui.status), true); assert.match(ui.vpnMessage, /VPN 已开启/);
});

test('clean-install login opens only the official browser; permission is requested on explicit VPN ON',async()=>{
  const {ui,calls,probeCalls}=harness();
  await ui.login();
  assert.ok(calls.includes('accountStart'));assert.ok(calls.some(c=>Array.isArray(c)&&c[0]==='browser'));
  assert.ok(!calls.includes('serviceStart'));assert.ok(!calls.includes('vpnStart'));assert.deepEqual(probeCalls,[]);
  await ui.refreshData();assert.equal(ui.hasAccount(),true);assert.equal(ui.vpn.connected,false);
  await ui.setVpn(true);assert.equal(calls.filter(c=>c==='serviceStart').length,1);
  assert.ok(calls.indexOf('releaseAccount')>calls.indexOf('serviceStart'));assert.equal(ui.vpn.connected,true);
});

test('manual device refresh cannot disable VPN controls or delay an established OFF',async()=>{
  let release;
  const h=harness();h.ui.status=running;await h.ui.setVpn(true);if(h.ui.refreshTask)await h.ui.refreshTask;
  h.native.onlinePeers=()=>new Promise(resolve=>{release=resolve;});
  const refreshing=h.ui.refreshData();for(let i=0;i<30&&!release;i++)await new Promise(resolve=>setImmediate(resolve));
  assert.ok(release);assert.equal(h.ui.busy,false);assert.equal(h.ui.peersUpdating,true);assert.equal(h.ui.vpnToggleEnabled(),true);
  await h.ui.setVpn(false);assert.equal(h.ui.vpn.connected,false);assert.equal(h.ui.vpnWanted(),false);
  release('{"ok":true,"peers":[]}');await refreshing;assert.equal(h.ui.peersUpdating,false);
});

test('user refusal of first VPN consent preserves account and stops retries',async()=>{
  const {ui,calls}=harness({}, {}, {}, {authorize:async()=>{throw new Error('user denied VPN consent');}});
  await ui.restoreSession();await ui.setVpn(true);
  assert.equal(ui.hasAccount(),true);assert.equal(ui.vpnWanted(),false);assert.equal(ui.vpn.connected,false);
  assert.equal(calls.filter(c=>c==='serviceStart').length,1);assert.ok(!calls.includes('releaseAccount'));
  assert.match(ui.vpnMessage,/denied/);assert.equal(ui.vpnToggleEnabled(),true);
});

test('cancel while first consent is pending fences a late authorization result',async()=>{
  let authorize;
  const {ui,calls}=harness({}, {}, {}, {authorize:()=>new Promise(resolve=>{authorize=resolve;})});
  await ui.restoreSession();const on=ui.setVpn(true);
  for(let i=0;i<100&&!authorize;i++)await new Promise(resolve=>setImmediate(resolve));assert.ok(authorize);
  const off=ui.setVpn(false);assert.equal(ui.vpnWanted(),false);
  authorize();await Promise.all([on,off]);assert.equal(ui.vpn.connected,false);
  assert.ok(!calls.includes('releaseAccount'));assert.ok(!calls.includes('vpnStart'));assert.equal(ui.hasAccount(),true);
});

test('logout during pending consent cancels handoff and cannot be undone by late authorization or refresh',async()=>{
  let authorize;
  const {ui,calls}=harness({}, {}, {}, {authorize:()=>new Promise(resolve=>{authorize=resolve;})});
  await ui.restoreSession();const on=ui.setVpn(true);
  for(let i=0;i<100&&!authorize;i++)await new Promise(resolve=>setImmediate(resolve));assert.ok(authorize);
  const logout=ui.logout();assert.equal(ui.vpnWanted(),false);
  authorize();await Promise.all([on,logout]);
  assert.equal(ui.hasAccount(),false);assert.equal(ui.vpn.connected,false);assert.equal(ui.vpnChanging,false);
  assert.ok(!calls.includes('releaseAccount'));assert.ok(!calls.includes('vpnStart'));assert.match(ui.message,/已退出/);
});

test('browser authentication observation can be cancelled without starting VPN or logging out',async()=>{
  const {ui,calls}=harness({getStatus:async()=>JSON.stringify(loggedOut)});
  await ui.login();assert.equal(ui.awaitingLogin,true);
  ui.cancelLogin();assert.equal(ui.awaitingLogin,false);assert.equal(ui.loginDeadline,0);assert.equal(ui.pollTimer,-1);
  assert.ok(!calls.includes('serviceStart'));assert.ok(!calls.includes('vpnStart'));assert.match(ui.message,/停止等待/);
});
