'use strict';
const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const Module=require('node:module');
const ts=require(process.env.TYPESCRIPT_MODULE);
const root=path.join(__dirname,'../entry/src/main/ets');
function compile(relative,deps={}) {
  const code=ts.transpileModule(fs.readFileSync(path.join(root,relative+'.ets'),'utf8'),{compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS}}).outputText;
  const mod=new Module(path.join(__dirname,'recovery-'+path.basename(relative)+'.cjs'),module);
  mod.filename=mod.id;mod.require=id=>Object.hasOwn(deps,id)?deps[id]:require(id);mod._compile(code,mod.filename);return mod.exports;
}
const model=compile('vpn/VpnRecoveryModel');
const turn=()=>new Promise(resolve=>setImmediate(resolve));
function harness(t,overrides={}) {
  let saved;const calls=[],reports=[];
  const port={readIntent:()=>saved,writeIntent:value=>{saved=JSON.parse(JSON.stringify(value));calls.push(['intent',value.enabled]);},
    recover:async()=>{calls.push('recover');},cancel:()=>calls.push('cancel'),disconnect:async()=>calls.push('disconnect'),
    publish:report=>reports.push({...report}),...overrides};
  const supervisor=new model.VpnRecoverySupervisor(port);t.after(()=>supervisor.stop());
  return {supervisor,port,calls,reports,saved:()=>saved};
}
test('intent is persisted before networking and a new runtime resumes only explicit ON',async t=>{
  const h=harness(t);await h.supervisor.setWanted(true,()=>{});
  assert.deepEqual(h.calls.slice(0,2),[['intent',true],'recover']);assert.equal(h.supervisor.diagnostics().phase,'connected');
  const next=harness(t,{readIntent:()=>h.saved()});next.supervisor.start();await next.supervisor.check();
  assert.equal(next.supervisor.wanted(),true);assert.equal(next.calls.filter(x=>x==='recover').length,1);
  const off=harness(t);off.supervisor.start();await off.supervisor.check();assert.deepEqual(off.calls,[]);
});
test('transient failures back off to 30 seconds, recover without resetting user intent and measure interruption',async t=>{
  t.mock.timers.enable({apis:['Date'],now:1000});let broken=true;
  const h=harness(t,{recover:async()=>{h.calls.push('recover');if(broken)throw new Error('offline');}});
  await assert.rejects(h.supervisor.setWanted(true,()=>{}),/offline/);
  for(const wait of [1000,2000,4000,8000,16000,30000]) {
    assert.equal(h.supervisor.diagnostics().nextRetryAt-Date.now(),wait);
    const count=h.calls.length;await h.supervisor.check();assert.equal(h.calls.length,count);
    t.mock.timers.tick(wait);await assert.rejects(h.supervisor.check(),/offline/);
  }
  broken=false;t.mock.timers.tick(30000);await h.supervisor.check();
  assert.equal(h.supervisor.wanted(),true);assert.equal(h.supervisor.diagnostics().phase,'connected');
  assert.equal(h.supervisor.diagnostics().attempts,0);assert.ok(h.supervisor.diagnostics().lastRecoveryMs>0);
});
test('authentication/authorization/other-VPN blockers stop retries until an explicit new ON',async t=>{
  let blocked=true;const h=harness(t,{recover:async()=>{h.calls.push('recover');if(blocked)throw new model.RecoveryBlocked('authorization revoked');}});
  await assert.rejects(h.supervisor.setWanted(true,()=>{}),/revoked/);assert.equal(h.supervisor.diagnostics().phase,'blocked');
  const count=h.calls.length;await h.supervisor.check();assert.equal(h.calls.length,count);
  blocked=false;await h.supervisor.setWanted(true,()=>{});assert.equal(h.supervisor.diagnostics().phase,'connected');
});
test('OFF cancels immediately, fences late recovery and persists before awaiting cleanup',async t=>{
  let release,stillWanted;
  const h=harness(t,{recover:(_intent,current)=>new Promise(resolve=>{stillWanted=current;release=resolve;})});
  const enabling=h.supervisor.setWanted(true,()=>{});await turn();
  const disabling=h.supervisor.setWanted(false,()=>{});
  assert.equal(stillWanted(),false);assert.equal(h.saved().enabled,false);assert.ok(h.calls.includes('cancel'));
  release();await Promise.all([enabling,disabling]);assert.equal(h.supervisor.diagnostics().phase,'off');
  assert.ok(h.calls.includes('disconnect'));assert.equal(h.supervisor.wanted(),false);
});
test('ON persistence failure acquires no resource; OFF persistence failure still performs actual disconnect',async t=>{
  const h=harness(t,{writeIntent:()=>{throw new Error('disk full');}});
  await assert.rejects(h.supervisor.setWanted(true,()=>{}),/disk full/);assert.ok(!h.calls.includes('recover'));
  await assert.rejects(h.supervisor.setWanted(false,()=>{}),/disk full/);
  assert.ok(h.calls.includes('cancel'));assert.ok(h.calls.includes('disconnect'));assert.equal(h.supervisor.wanted(),false);
});
test('corrupt intent fails closed without reconstructing ON from stale snapshots',async t=>{
  const h=harness(t,{readIntent:()=>model.readVpnIntent('{"enabled":true}')});h.supervisor.start();await h.supervisor.check();
  assert.equal(h.supervisor.wanted(),false);assert.equal(h.supervisor.diagnostics().phase,'blocked');assert.ok(!h.calls.includes('recover'));
});
test('recovery checks are single-flight and use runtime timer without a page observer',async t=>{
  let release,count=0;
  const h=harness(t,{recover:()=>new Promise(resolve=>{count++;release=resolve;})});
  const opening=h.supervisor.setWanted(true,()=>{});await turn();
  const a=h.supervisor.check(),b=h.supervisor.check();await turn();assert.equal(count,1);
  release();await Promise.all([opening,a,b]);
  t.mock.timers.enable({apis:['setTimeout'],now:1000});
  await h.supervisor.setWanted(false,()=>{});
  h.port.readIntent=()=>Object.assign(new model.VpnIntent(),{enabled:true,revision:'9-10'});
  h.supervisor.start();t.mock.timers.tick(1);await turn();assert.equal(count,2);
  release();await turn();h.supervisor.stop();
});

const controls=compile('pages/ClientModel');
const vpn=compile('vpn/VpnSessionModel');
const service=compile('vpn/NetworkServiceModel',{'./VpnSessionModel':vpn,'../pages/ClientModel':controls,'./VpnRecoveryModel':model});
const clientModule=compile('vpn/NetworkServiceClient',{'./NetworkServiceModel':service,'./VpnSessionModel':vpn,'../pages/ClientModel':controls});
function platformHarness(overrides={}) {
  const calls=[],reports=[];let environment={online:true,ownVpn:false,otherVpn:false};
  const owner=Object.assign(new service.ServiceSnapshot(),{ownerId:'1-2',coreId:'9-9',coreAlive:true,serviceReady:true,phase:'idle'});
  const client={pending:()=>false,ensure:async()=>{calls.push('ensure');return owner;},
    setEnabled:async(enabled,_progress,current,_intent,repair)=>{calls.push(['setEnabled',enabled,repair]);environment.ownVpn=true;owner.connected=true;owner.ipv4='100.64.1.1';return owner;},cancelEnable:()=>calls.push('cancel')};
  const native={getStatus:async()=>JSON.stringify({ok:true,loggedIn:true,backendState:'Running',tailscaleIPs:['100.64.1.1']})};
  Object.assign(client,overrides.client);Object.assign(native,overrides.native);
  const mod=compile('vpn/VpnRecoveryPlatform',{'libtailscale_napi.so':{default:native},'../pages/ClientModel':controls,
    './NetworkServiceClient':clientModule,'./NetworkClientPlatform':{},'./NetworkServiceStore':{NetworkServiceStore:class{}},
    './NetworkServiceModel':service,'./VpnRecoveryModel':model,'./NetworkEnvironment':{inspectNetworks:async()=>environment}});
  const port=new mod.PlatformVpnRecovery(client,{read:()=>owner},'/private',s=>reports.push({...s}),()=>{});
  return {port,calls,owner,reports,environment:value=>{environment=value;}};
}
test('an intact live data path does not depend on control-server/peer queries or recreate anything',async()=>{
  const h=platformHarness({native:{getStatus:async()=>{throw new Error('control unavailable');}}});
  h.owner.connected=true;h.owner.attached=true;h.environment({online:true,ownVpn:true,otherVpn:false});
  await h.port.recover({},()=>true,()=>{});assert.deepEqual(h.calls,['ensure']);
});
test('OS interface removal repairs only the interface of a healthy core',async()=>{
  const h=platformHarness();h.owner.attached=true;h.owner.connected=true;
  await h.port.recover({revision:'8-9'},()=>true,()=>{});assert.deepEqual(h.calls,['ensure',['setEnabled',true,true]]);
});
test('control reconnect on an intact interface is retried without TUN teardown',async()=>{
  const h=platformHarness();h.owner.attached=true;h.environment({online:true,ownVpn:true,otherVpn:false});
  await assert.rejects(h.port.recover({},()=>true,()=>{}),/原核心/);assert.deepEqual(h.calls,['ensure']);
});
test('offline, foreign VPN and revoked credentials never start/attach in the recovery critical path',async()=>{
  const h=platformHarness();h.environment({online:false,ownVpn:false,otherVpn:false});
  await assert.rejects(h.port.recover({},()=>true,()=>{}),/物理网络/);assert.deepEqual(h.calls,[]);
  h.environment({online:true,ownVpn:false,otherVpn:true});
  await assert.rejects(h.port.recover({},()=>true,()=>{}),model.RecoveryBlocked);assert.deepEqual(h.calls,[]);
  const expired=platformHarness({native:{getStatus:async()=>JSON.stringify({ok:true,loggedIn:false,backendState:'NeedsLogin'})}});
  await assert.rejects(expired.port.recover({},()=>true,()=>{}),model.RecoveryBlocked);assert.deepEqual(expired.calls,['ensure']);
});
test('late preflight results after OFF cannot acquire resources',async()=>{
  const h=platformHarness();let current=true;
  const pending=h.port.recover({},()=>current,()=>{});current=false;await pending;assert.deepEqual(h.calls,[]);
});
test('service permission blockers become suspended recovery, not unlimited SDK retries',async()=>{
  const h=platformHarness({client:{setEnabled:async()=>{h.owner.stopReason='authorization_denied';throw new Error('denied');}}});
  await assert.rejects(h.port.recover({},()=>true,()=>{}),model.RecoveryBlocked);
});

test('a native connected report without OS confirmation is not published as successful recovery',async()=>{
  const h=platformHarness({client:{setEnabled:async()=>Object.assign(h.owner,{connected:true,ipv4:'100.64.1.1'})}});
  await assert.rejects(h.port.recover({},()=>true,()=>{}),/尚未确认/);
  assert.ok(h.reports.every(s=>!s.connected));
});

function environmentModule(nets) {
  const calls=[];
  const connection={NetBearType:{BEARER_VPN:4},NetCap:{NET_CAPABILITY_INTERNET:12},getAllNets:async()=>nets,
    getNetCapabilities:async net=>net.caps,getConnectionProperties:async net=>{calls.push('properties');return net.props;}};
  return {mod:compile('vpn/NetworkEnvironment',{'@kit.NetworkKit':{connection},'./NetworkServiceClient':clientModule}),calls};
}
test('OS network inspection separates physical connectivity, expected VPN and foreign VPN',async()=>{
  const physical={caps:{bearerTypes:[1],networkCap:[12]}},own={caps:{bearerTypes:[4]},props:{linkAddresses:[{address:{address:'100.64.1.1'}}]}};
  const h=environmentModule([physical,own]);const result=await h.mod.inspectNetworks('100.64.1.1');
  assert.equal(result.online,true);assert.equal(result.ownVpn,true);assert.equal(result.otherVpn,false);
  assert.equal((await h.mod.inspectNetworks('')).otherVpn,true);
  own.props.linkAddresses=[];assert.equal((await h.mod.inspectNetworks('100.64.1.1')).ownVpn,false);
});
test('atomic intent storage roundtrips without credentials; malformed/missing records are not ON',()=>{
  const files=new Map(),writes=[];
  const fileIo={OpenMode:{CREATE:1,WRITE_ONLY:2,TRUNC:4},accessSync:p=>files.has(p),readTextSync:p=>files.get(p),
    openSync:p=>({fd:p}),writeSync:(p,value)=>files.set(p,value),closeSync:()=>{},renameSync:(a,b)=>{writes.push([a,b]);files.set(b,files.get(a));files.delete(a);}};
  const storeModule=compile('vpn/NetworkServiceStore',{'@kit.CoreFileKit':{fileIo},'./NetworkServiceModel':service,'./VpnRecoveryModel':model});
  const store=new storeModule.NetworkServiceStore('/private');assert.equal(store.intent(),undefined);
  const intent=Object.assign(new model.VpnIntent(),{enabled:true,revision:'1-2'});store.saveIntent(intent);
  assert.deepEqual(store.intent(),{...intent});assert.deepEqual(writes,[['/private/vpn-intent.json.tmp','/private/vpn-intent.json']]);
  assert.deepEqual(Object.keys(JSON.parse(files.get('/private/vpn-intent.json'))).sort(),['enabled','revision','version']);
  files.set('/private/vpn-intent.json','null');assert.throws(()=>store.intent());
});
