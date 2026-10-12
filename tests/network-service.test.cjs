'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');
const ts = require(process.env.TYPESCRIPT_MODULE);
const dir=path.join(__dirname,'../entry/src/main/ets');
function compile(relative,deps={}) {
  const code=ts.transpileModule(fs.readFileSync(path.join(dir,relative+'.ets'),'utf8'),{compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS}}).outputText;
  const mod=new Module(path.join(__dirname,'service-'+path.basename(relative)+'.cjs'),module);
  mod.filename=mod.id;mod.require=id=>Object.hasOwn(deps,id)?deps[id]:require(id);mod._compile(code,mod.filename);return mod.exports;
}
const controls=compile('pages/ClientModel');
const vpn=compile('vpn/VpnSessionModel');
const model=compile('vpn/NetworkServiceModel',{'./VpnSessionModel':vpn,'../pages/ClientModel':controls});
const clients=compile('vpn/NetworkServiceClient',{'./NetworkServiceModel':model,'./VpnSessionModel':vpn,'../pages/ClientModel':controls});
const running={ok:true,loggedIn:true,backendState:'Running',tailscaleIPs:['100.64.1.1']};
const turn=()=>new Promise(resolve=>setImmediate(resolve));
async function until(predicate){for(let i=0;i<200;i++){if(predicate())return;await turn();}throw new Error('service transition did not complete');}
function actorHarness(t,overrides={}) {
  const actor=new model.NetworkServiceActor(),calls=[],snapshots=[];
  let request,latest,alive=true,attached=false,connecting=false;
  const port={
    orphanedNetwork:()=>false,
    boot:async()=>{calls.push('boot');return '{"ok":true}';},
    control:async()=>JSON.stringify(running),
    status:async()=>JSON.stringify(Object.assign(new vpn.VpnState(),{coreId:'9-9',coreAlive:alive,coreOwner:true,attached,
      startedAt:Date.now(),connected:attached&&!connecting,state:attached?(connecting?'connecting':'connected'):'disconnected',ipv4:attached?'100.64.1.1':''})),
    create:async()=>{calls.push('create');return 17;},protect:async()=>{calls.push('protect');},
    attach:async()=>{calls.push('attach');attached=true;return '{"ok":true}';},
    detach:async()=>{calls.push('detach');attached=false;return '{"ok":true}';},
    closeDescriptor:fd=>calls.push(['closeDescriptor',fd]),destroy:async()=>{calls.push('destroy');},
    closeCore:async()=>{calls.push('closeCore');alive=false;return '{"ok":true}';},
    request:()=>request,
    publish:s=>{ latest=model.readServiceSnapshot(JSON.stringify(s));snapshots.push(latest); },
    delay:turn,...overrides
  };
  const task=actor.run(port,'1-2');t.after(async()=>{actor.cancel('test_shutdown');await task;});
  const command=(enabled,id='3-4')=>{request=Object.assign(new model.ServiceCommand(),{ownerId:'1-2',commandId:id,enabled});};
  return {actor,calls,snapshots,port,task,command,setRequest:c=>{request=c;},latest:()=>latest,
    reconnect:value=>{connecting=value;},die:()=>{alive=false;}};
}

test('actor boots without a system interface and retains one core across repeated ON/OFF',async t=>{
  const h=actorHarness(t);await until(()=>h.latest()?.serviceReady);
  assert.equal(h.calls.filter(x=>x==='boot').length,1);assert.ok(!h.calls.includes('create'));
  for(let i=0;i<3;i++){
    h.command(true,`3-${i}`);await until(()=>h.latest()?.connected);
    assert.equal(h.latest().coreId,'9-9');assert.equal(h.latest().descriptorClosed,true);
    h.command(false,`4-${i}`);await until(()=>h.latest()?.phase==='idle'&&h.latest().commandId===`4-${i}`);
    assert.equal(h.latest().coreAlive,true);assert.equal(h.latest().connected,false);
    assert.equal(h.latest().detached,true);assert.equal(h.latest().destroyed,true);
  }
  assert.equal(h.calls.filter(x=>x==='boot').length,1);assert.equal(h.calls.filter(x=>x==='closeCore').length,0);
  assert.equal(h.calls.filter(x=>x==='attach').length,3);assert.equal(h.calls.filter(x=>x==='detach').length,3);
  assert.equal(h.calls.filter(x=>x==='destroy').length,3);
});

test('temporary control reconnect longer than old 90s timeout never tears down an attached VPN',async t=>{
  t.mock.timers.enable({apis:['Date'],now:1000});
  const h=actorHarness(t);await until(()=>h.latest()?.serviceReady);h.command(true);await until(()=>h.latest()?.connected);
  h.reconnect(true);t.mock.timers.tick(180000);await until(()=>h.latest()?.phase==='reconnecting');
  assert.equal(h.latest().coreAlive,true);assert.equal(h.latest().destroyed,false);
  assert.ok(!h.calls.includes('detach'));assert.ok(!h.calls.includes('closeCore'));
  h.reconnect(false);await until(()=>h.latest()?.connected);assert.equal(h.latest().coreId,'9-9');
});

test('OFF cancels late interface creation, closes it once and does not attach or replace the core',async t=>{
  let resolve;const h=actorHarness(t,{create:()=>new Promise(r=>{resolve=r;})});
  await until(()=>h.latest()?.serviceReady);h.command(true);await until(()=>h.latest()?.phase==='create');
  h.command(false,'4-5');resolve(29);await until(()=>h.latest()?.phase==='idle'&&h.latest().commandId==='4-5');
  assert.ok(!h.calls.includes('attach'));assert.ok(!h.calls.includes('closeCore'));
  assert.deepEqual(h.calls.filter(Array.isArray),[['closeDescriptor',29]]);assert.equal(h.calls.filter(x=>x==='destroy').length,1);
  assert.equal(h.latest().coreAlive,true);
});

test('actor obeys live authentication and waits for real readiness before acquiring a descriptor',async t=>{
  let ready=false;const h=actorHarness(t,{control:async()=>JSON.stringify({...running,backendState:ready?'Running':'Starting'})});
  await until(()=>h.latest()?.serviceReady);h.command(true);await until(()=>h.latest()?.phase==='waiting_core');
  assert.ok(!h.calls.includes('create'));ready=true;await until(()=>h.latest()?.connected);
});

test('expired authentication fails before creating any system interface and retains service',async t=>{
  const h=actorHarness(t,{control:async()=>JSON.stringify({ok:true,loggedIn:false,backendState:'NeedsLogin'})});
  await until(()=>h.latest()?.serviceReady);h.command(true);await until(()=>h.latest()?.phase==='error');
  assert.match(h.latest().error,/认证/);assert.ok(!h.calls.includes('create'));assert.ok(!h.calls.includes('closeCore'));
});

test('SDK protection failure releases descriptor/network but keeps the initialized core retryable',async t=>{
  let denied=true;const h=actorHarness(t,{protect:async()=>{if(denied)throw new Error('protection denied');}});
  await until(()=>h.latest()?.serviceReady);h.command(true);await until(()=>h.latest()?.phase==='error');
  assert.equal(h.latest().detached,true);assert.equal(h.latest().destroyed,true);assert.equal(h.latest().coreAlive,true);
  assert.ok(!h.calls.includes('attach'));assert.equal(h.calls.filter(x=>x==='closeCore').length,0);
  denied=false;h.command(true,'5-6');await until(()=>h.latest()?.connected);assert.equal(h.latest().coreId,'9-9');
});

test('failed detach stays cleanup_pending; a new OFF retries cleanup without starting another core',async t=>{
  let fail=true;const h=actorHarness(t,{detach:async()=>{h.calls.push('detach');if(fail)throw new Error('detach failed');return '{"ok":true}';}});
  await until(()=>h.latest()?.serviceReady);h.command(true);await until(()=>h.latest()?.connected);h.command(false,'4-5');
  await until(()=>h.latest()?.phase==='cleanup_pending');assert.equal(h.latest().detached,false);assert.equal(h.latest().ok,false);
  fail=false;h.command(false,'6-7');await until(()=>h.latest()?.phase==='idle');assert.equal(h.latest().coreAlive,true);
});

test('unconfirmed original descriptor close never reports successful ON or cleanup',async t=>{
  const h=actorHarness(t,{closeDescriptor:()=>{throw new Error('close unavailable');}});
  await until(()=>h.latest()?.serviceReady);h.command(true);await until(()=>h.latest()?.phase==='cleanup_pending');
  assert.equal(h.latest().connected,false);assert.equal(h.latest().descriptorClosed,false);assert.equal(h.latest().ok,false);
});

test('system destruction and true engine failure have separate stop reasons and release resources',async t=>{
  const h=actorHarness(t);await until(()=>h.latest()?.serviceReady);h.command(true);await until(()=>h.latest()?.connected);
  h.die();await h.task;assert.equal(h.latest().phase,'stopped');assert.equal(h.latest().stopReason,'core_failed');
  assert.equal(h.latest().coreAlive,false);assert.equal(h.latest().detached,true);assert.equal(h.latest().destroyed,true);
  const second=actorHarness(t);await until(()=>second.latest()?.serviceReady);second.actor.cancel();await second.task;
  assert.equal(second.latest().stopReason,'system_destroyed');
});

test('commands for a different owner generation cannot mutate an existing service',async t=>{
  const h=actorHarness(t);await until(()=>h.latest()?.serviceReady);
  h.setRequest(Object.assign(new model.ServiceCommand(),{ownerId:'7-8',commandId:'3-4',enabled:true}));
  await turn();await turn();assert.ok(!h.calls.includes('create'));assert.equal(h.latest().desiredEnabled,false);
});

test('replacement host cleans an orphan network only after exclusive core ownership',async t=>{
  const h=actorHarness(t,{orphanedNetwork:()=>true});await until(()=>h.latest()?.serviceReady);
  assert.equal(h.calls.filter(x=>x==='destroy').length,1);assert.ok(!h.calls.includes('create'));
  assert.equal(h.latest().destroyed,true);assert.equal(h.latest().coreAlive,true);
  const other=actorHarness(t,{orphanedNetwork:()=>true,status:async()=>JSON.stringify(Object.assign(new vpn.VpnState(),{coreId:'9-9',coreAlive:true,coreOwner:false}))});
  await other.task;assert.ok(!other.calls.includes('destroy'));assert.equal(other.latest().phase,'cleanup_pending');
});

test('snapshot storage failure cannot skip actual descriptor and network cleanup',async t=>{
  const h=actorHarness(t);await until(()=>h.latest()?.serviceReady);h.command(true);await until(()=>h.latest()?.connected);
  h.port.publish=()=>{throw new Error('storage full');};h.actor.cancel();await h.task;
  assert.ok(h.calls.includes('detach'));assert.ok(h.calls.includes('destroy'));assert.ok(h.calls.includes('closeCore'));
});

function clientHarness(overrides={}) {
  const calls=[];let snapshot=Object.assign(new model.ServiceSnapshot(),{ownerId:'1-2',coreId:'9-9',coreAlive:true,serviceReady:true,phase:'idle',timestamp:Date.now()});
  const port={start:async id=>{calls.push('sdkStart');snapshot.ownerId=id;},stop:async()=>{calls.push('sdkStop');},
    read:()=>snapshot,connect:async()=>{calls.push('connect');return '{"ok":true}';},closeProxy:async()=>{calls.push('closeProxy');return '{"ok":true}';},
    status:async()=>JSON.stringify(Object.assign(new vpn.VpnState(),{coreAlive:snapshot.coreAlive,coreId:snapshot.coreId,connected:snapshot.connected,
      attached:snapshot.connected,state:snapshot.state,ipv4:snapshot.ipv4})),delay:turn,
    command:c=>{calls.push(['command',c.enabled]);Object.assign(snapshot,{commandId:c.commandId,desiredEnabled:c.enabled,
      connected:c.enabled,phase:c.enabled?'connected':'idle',state:c.enabled?'connected':'disconnected',
      created:c.enabled,processProtected:c.enabled,detached:!c.enabled,destroyed:!c.enabled,attached:c.enabled,ipv4:c.enabled?'100.64.1.1':''});},...overrides};
  const client=new clients.NetworkServiceClient(port);return{client,calls,port,snapshot};
}

test('client reuses a healthy existing core; normal OFF issues no SDK stop/start or core close',async()=>{
  const h=clientHarness();await h.client.ensure(()=>{});await h.client.setEnabled(true,()=>{});await h.client.setEnabled(false,()=>{});
  assert.ok(!h.calls.includes('sdkStart'));assert.ok(!h.calls.includes('sdkStop'));assert.ok(!h.calls.includes('closeProxy'));
  assert.equal(h.snapshot.coreId,'9-9');assert.equal(h.snapshot.coreAlive,true);
});

test('stale heartbeat with a live native core is not grounds to replace it',async()=>{
  const h=clientHarness();h.snapshot.timestamp=Date.now()-60000;
  await assert.rejects(h.client.ensure(()=>{}),/核心仍在运行/);
  assert.ok(!h.calls.includes('sdkStop'));assert.ok(!h.calls.includes('sdkStart'));assert.ok(!h.calls.includes('closeProxy'));
});

test('snapshot/native generation mismatch cannot certify a connected VPN',async()=>{
  const h=clientHarness({status:async()=>JSON.stringify(Object.assign(new vpn.VpnState(),{coreAlive:true,coreId:'99-99'}))});
  await assert.rejects(h.client.ensure(()=>{}),/实例已变化/);assert.ok(!h.calls.includes('sdkStart'));assert.ok(!h.calls.includes('sdkStop'));
});

test('native disconnected state overrides a cached connected report',async()=>{
  const h=clientHarness({status:async()=>JSON.stringify(Object.assign(new vpn.VpnState(),{coreAlive:true,coreId:'9-9',state:'connecting',ipv4:'100.64.1.1',attached:true}))});
  Object.assign(h.snapshot,{connected:true,state:'connected',ipv4:'100.64.1.1',created:true,processProtected:true,detached:false,destroyed:false});
  const s=await h.client.observe();assert.equal(s.connected,false);assert.equal(s.phase,'reconnecting');
});

test('concurrent client mutations are rejected and timed-out ON publishes an OFF cancellation',async t=>{
  t.mock.timers.enable({apis:['setTimeout','Date'],now:1000});let release;
  const h=clientHarness({command:c=>{h.calls.push(['command',c.enabled]);},delay:()=>new Promise(resolve=>{release=resolve;})});
  const first=h.client.setEnabled(true,()=>{});await turn();
  await assert.rejects(h.client.setEnabled(false,()=>{}),/正在处理中/);
  const caught=assert.rejects(first,/超时/);t.mock.timers.tick(36000);release();await caught;
  assert.deepEqual(h.calls.filter(Array.isArray),[['command',true],['command',false]]);
});

test('late service authorization retains an SDK lease until it settles, then reuses the idle service',async t=>{
  t.mock.timers.enable({apis:['setTimeout','Date'],now:1000});let release,available=false;
  const h=clientHarness({read:()=>available?h.snapshot:undefined,start:()=>new Promise(resolve=>{release=()=>{available=true;h.snapshot.timestamp=Date.now();resolve();};})});
  const first=assert.rejects(h.client.ensure(()=>{}),/授权.*超时/);await turn();t.mock.timers.tick(60001);await first;
  assert.equal(h.client.pending(),true);await assert.rejects(h.client.ensure(()=>{}),/仍在处理中/);
  release();await turn();assert.equal(h.client.pending(),false);await h.client.ensure(()=>{});
});

test('schema rejects inconsistent connected reports and non-string owner/command identifiers',()=>{
  const snapshot=Object.assign(new model.ServiceSnapshot(),{ownerId:'1-2',coreId:'9-9',coreAlive:true,serviceReady:true,timestamp:1000});
  assert.throws(()=>model.readServiceSnapshot(JSON.stringify({...snapshot,connected:true,state:'connected',ipv4:'100.64.1.1'})));
  assert.throws(()=>model.readServiceCommand(JSON.stringify({version:1,ownerId:123,commandId:'1-2',enabled:true,shutdown:false})));
  assert.throws(()=>model.readServiceCommand(JSON.stringify({version:1,ownerId:'1-2',commandId:'1-3',enabled:'true',shutdown:false})));
});
