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
const recovery=compile('vpn/VpnRecoveryModel');
const model=compile('vpn/NetworkServiceModel',{'./VpnSessionModel':vpn,'../pages/ClientModel':controls,'./VpnRecoveryModel':recovery});
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
    intent:()=>undefined,
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

test('repair command replaces only the lost OS interface and retains the authoritative core',async t=>{
  const h=actorHarness(t);await until(()=>h.latest()?.serviceReady);h.command(true);await until(()=>h.latest()?.connected);
  h.setRequest(Object.assign(new model.ServiceCommand(),{ownerId:'1-2',commandId:'7-8',enabled:true,repair:true}));
  await until(()=>h.latest()?.connected&&h.latest().commandId==='7-8');
  assert.equal(h.calls.filter(x=>x==='boot').length,1);assert.ok(!h.calls.includes('closeCore'));
  assert.equal(h.calls.filter(x=>x==='create').length,2);assert.equal(h.calls.filter(x=>x==='detach').length,1);
  assert.equal(h.latest().coreId,'9-9');
});

test('persistent OFF cancels a late SDK creation even if OFF command publication is unavailable',async t=>{
  let release;const intent=Object.assign(new recovery.VpnIntent(),{enabled:true,revision:'8-9'});
  const h=actorHarness(t,{intent:()=>intent,create:()=>new Promise(resolve=>{release=resolve;})});
  await until(()=>h.latest()?.serviceReady);
  h.setRequest(Object.assign(new model.ServiceCommand(),{ownerId:'1-2',commandId:'3-4',enabled:true,intentId:'8-9'}));
  await until(()=>h.latest()?.phase==='create');intent.enabled=false;release(27);
  await until(()=>h.latest()?.phase==='idle');assert.ok(!h.calls.includes('attach'));
  assert.deepEqual(h.calls.filter(Array.isArray),[['closeDescriptor',27]]);
});

test('stale intent revisions cannot enable a new owner or revive a cancelled ON',async t=>{
  const intent=Object.assign(new recovery.VpnIntent(),{enabled:true,revision:'8-9'});
  const h=actorHarness(t,{intent:()=>intent});await until(()=>h.latest()?.serviceReady);h.command(true);
  await turn();await turn();assert.ok(!h.calls.includes('create'));
  h.setRequest(Object.assign(new model.ServiceCommand(),{ownerId:'1-2',commandId:'4-5',enabled:true,intentId:'8-9'}));
  await until(()=>h.latest()?.connected);intent.revision='9-10';
  await until(()=>h.latest()?.phase==='idle');assert.equal(h.latest().desiredEnabled,false);
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

test('authorized native map permits ON before Running without a slow account-status query',async t=>{
  const h=actorHarness(t,{control:async()=>{throw new Error('must not wait on account query');}});
  const status=h.port.status;
  h.port.status=async()=>JSON.stringify({...JSON.parse(await status()),networkMapReady:true,assignedIPv4:'100.64.1.1'});
  await until(()=>h.latest()?.serviceReady);h.command(true);await until(()=>h.latest()?.connected);
  assert.ok(h.calls.includes('create'));assert.ok(h.calls.includes('protect'));assert.ok(h.calls.includes('attach'));
  assert.equal(h.latest().networkMapReady,true);
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
  const port={beginHandoff:()=>{},finishHandoff:()=>{},releaseAccount:async()=>'{"ok":true}',start:async id=>{calls.push('sdkStart');snapshot.ownerId=id;},stop:async()=>{calls.push('sdkStop');},
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

test('old ready snapshot and refused socket wait for the listener without repeated SDK starts',async()=>{
  let attempts=0,delays=0,ownerId;
  const h=clientHarness({
    start:async id=>{h.calls.push('sdkStart');ownerId=id;},
    connect:async()=>{h.calls.push('connect');attempts++;return attempts<4?
      '{"ok":false,"error":"dial unix /private/tailscale/vpn.sock: connect: connection refused"}':'{"ok":true}';},
    delay:async()=>{delays++;Object.assign(h.snapshot,{ownerId,coreId:'11-12',timestamp:Date.now()});await turn();}
  });
  const [first,second]=await Promise.all([h.client.ensure(()=>{},true),h.client.ensure(()=>{},true)]);
  assert.equal(first.coreId,'11-12');assert.equal(second.coreId,first.coreId);
  assert.equal(attempts,4);assert.equal(delays,3);
  assert.equal(h.calls.filter(x=>x==='sdkStart').length,1);
  assert.ok(!h.calls.includes('sdkStop'));
  assert.ok(!h.calls.some(Array.isArray));
});

test('permanently refused socket stays failed after bounded retry and preserves diagnostic cause',async t=>{
  t.mock.timers.enable({apis:['setTimeout','Date'],now:1000});
  const h=clientHarness({
    connect:async()=>'{"ok":false,"error":"vpn.sock: connection refused"}',
    delay:async()=>{h.snapshot.timestamp=Date.now();t.mock.timers.tick(10000);await turn();}
  });
  await assert.rejects(h.client.ensure(()=>{},true),/本地.*服务.*超时.*connection refused/);
  assert.equal(h.client.pending(),false);
  assert.equal(h.calls.filter(x=>x==='sdkStart').length,1);
  assert.ok(!h.calls.includes('sdkStop'));assert.ok(!h.calls.some(Array.isArray));
});

test('new owner startup error is surfaced without retrying a stopped core',async()=>{
  const h=clientHarness({start:async id=>{Object.assign(h.snapshot,{ownerId:id,serviceReady:false,phase:'stopped',error:'core startup failed'});}});
  h.port.connect=async()=>'{"ok":false,"error":"connection refused"}';
  await assert.rejects(h.client.ensure(()=>{},true),/core startup failed/);
});

test('confirmed stopped generation is replaced once and accepts a fresh recovery intent',async()=>{
  const h=clientHarness();Object.assign(h.snapshot,{phase:'stopped',coreAlive:false,serviceReady:false,stopReason:'system_destroyed'});
  h.port.start=async id=>{h.calls.push('sdkStart');Object.assign(h.snapshot,{ownerId:id,coreId:'11-12',coreAlive:true,serviceReady:true,phase:'idle',timestamp:Date.now()});};
  await h.client.ensure(()=>{},true,()=>true,'7-8');
  const result=await h.client.setEnabled(true,()=>{},()=>true,'7-8');
  assert.equal(result.connected,true);assert.equal(result.coreId,'11-12');
  assert.equal(h.calls.filter(x=>x==='sdkStart').length,1);assert.equal(h.calls.filter(x=>x==='sdkStop').length,1);
});

test('OFF during pending SDK bootstrap fences ON before publishing an enable command',async()=>{
  let release,available=false;
  const h=clientHarness({read:()=>available?h.snapshot:undefined,start:()=>new Promise(resolve=>{release=()=>{available=true;h.snapshot.timestamp=Date.now();resolve();};})});
  let current=true;const opening=h.client.ensure(()=>{},true,()=>current,'7-8');const rejected=assert.rejects(opening,/取消/);
  await turn();current=false;h.client.cancelEnable();release();await rejected;
  assert.ok(!h.calls.some(x=>Array.isArray(x)&&x[0]==='command'&&x[1]));
  assert.equal(h.snapshot.connected,false);assert.equal(h.snapshot.coreAlive,true);
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
  t.mock.timers.enable({apis:['setTimeout','setInterval','Date'],now:1000});let release,available=false;
  const h=clientHarness({read:()=>available?h.snapshot:undefined,start:()=>new Promise(resolve=>{release=()=>{available=true;h.snapshot.timestamp=Date.now();resolve();};})});
  const first=assert.rejects(h.client.ensure(()=>{},true),/授权.*超时/);await turn();t.mock.timers.tick(60001);await first;
  assert.equal(h.client.pending(),true);await assert.rejects(h.client.ensure(()=>{}),/仍在处理中/);
  release();await turn();assert.equal(h.client.pending(),false);await h.client.ensure(()=>{});
});

test('schema rejects inconsistent connected reports and non-string owner/command identifiers',()=>{
  const snapshot=Object.assign(new model.ServiceSnapshot(),{ownerId:'1-2',coreId:'9-9',coreAlive:true,serviceReady:true,timestamp:1000});
  assert.throws(()=>model.readServiceSnapshot(JSON.stringify({...snapshot,connected:true,state:'connected',ipv4:'100.64.1.1'})));
  assert.throws(()=>model.readServiceCommand(JSON.stringify({version:1,ownerId:123,commandId:'1-2',enabled:true,shutdown:false})));
  assert.throws(()=>model.readServiceCommand(JSON.stringify({version:1,ownerId:'1-2',commandId:'1-3',enabled:'true',shutdown:false})));
});

test('cold recovery without a user action cannot request system VPN authorization',async()=>{
  const h=clientHarness({read:()=>undefined});
  await assert.rejects(h.client.ensure(()=>{}),clients.VpnAuthorizationRequired);
  assert.ok(!h.calls.includes('sdkStart'));assert.ok(!h.calls.includes('closeProxy'));
});

test('authorized preparation releases the account only after new-owner acknowledgment, before boot',async()=>{
  let available=false;
  const h=clientHarness({
    read:()=>available?h.snapshot:undefined,
    start:async(id)=>{h.calls.push('sdkStart');available=true;Object.assign(h.snapshot,{ownerId:id,phase:'handoff_wait',coreAlive:false,serviceReady:false});},
    releaseAccount:async()=>{h.calls.push('releaseAccount');assert.equal(h.snapshot.phase,'handoff_wait');return '{"ok":true}';},
    command:c=>{h.calls.push('handoff');assert.equal(c.handoff,true);assert.equal(c.enabled,false);assert.equal(c.intentId,'7-8');
      Object.assign(h.snapshot,{phase:'idle',coreAlive:true,serviceReady:true,coreId:'11-12'});}
  });
  const result=await h.client.ensure(()=>{},true,()=>true,'7-8');
  assert.equal(result.coreId,'11-12');
  assert.ok(h.calls.indexOf('sdkStart')<h.calls.indexOf('releaseAccount'));
  assert.ok(h.calls.indexOf('releaseAccount')<h.calls.indexOf('handoff'));
  assert.ok(h.calls.indexOf('handoff')<h.calls.indexOf('connect'));
});

test('refused authorization retains the account core and sends no handoff or enable',async()=>{
  let releases=0;
  const h=clientHarness({read:()=>undefined,start:async()=>{throw new Error('permission denied');},releaseAccount:async()=>{releases++;return '{"ok":true}';}});
  await assert.rejects(h.client.ensure(()=>{},true,()=>true,'7-8'),/denied/);
  assert.equal(releases,0);assert.ok(!h.calls.some(Array.isArray));assert.equal(h.client.pending(),false);
});

test('extension acknowledgment progresses handoff and ON while the SDK start Promise is still pending',async()=>{
  let available=false,settleStart,released=false;
  const h=clientHarness({read:()=>available?h.snapshot:undefined,
    start:id=>{available=true;Object.assign(h.snapshot,{ownerId:id,phase:'handoff_wait',coreAlive:false,serviceReady:false});
      return new Promise(resolve=>{settleStart=resolve;});},
    releaseAccount:async()=>{released=true;return '{"ok":true}';},
    command:c=>{h.calls.push(['command',c.enabled]);
      if(c.handoff){assert.equal(released,true);Object.assign(h.snapshot,{phase:'idle',coreAlive:true,serviceReady:true,coreId:'11-12'});}
      else{Object.assign(h.snapshot,{commandId:c.commandId,connected:c.enabled,phase:c.enabled?'connected':'idle',state:c.enabled?'connected':'disconnected',
        created:c.enabled,processProtected:c.enabled,detached:!c.enabled,destroyed:!c.enabled,attached:c.enabled,ipv4:c.enabled?'100.64.1.1':''});}
    }});
  const opening=h.client.ensure(()=>{},true,()=>true,'7-8');
  await until(()=>released);await opening;
  assert.equal(h.client.pending(),false);
  const connected=await h.client.setEnabled(true,()=>{},()=>true,'7-8');assert.equal(connected.connected,true);
  settleStart();await turn();assert.equal(h.client.pending(),false);
  await h.client.setEnabled(false,()=>{});assert.equal(h.snapshot.connected,false);
});

test('cancellation before extension acknowledgment retains the account despite a pending SDK start',async t=>{
  t.mock.timers.enable({apis:['Date'],now:1000});let settleStart,current=true,releases=0;
  const h=clientHarness({read:()=>undefined,start:()=>new Promise(resolve=>{settleStart=resolve;}),
    releaseAccount:async()=>{releases++;return '{"ok":true}';},delay:async()=>{current=false;await turn();}});
  await assert.rejects(h.client.ensure(()=>{},true,()=>current,'7-8'),/取消/);
  assert.equal(releases,0);assert.equal(h.client.pending(),true);assert.ok(!h.calls.some(Array.isArray));
  settleStart();await turn();assert.equal(h.client.pending(),false);
});

test('late SDK rejection after an acknowledged handoff does not become an unhandled error or replace its owner',async()=>{
  let available=false,rejectStart;
  const h=clientHarness({read:()=>available?h.snapshot:undefined,
    start:id=>{available=true;Object.assign(h.snapshot,{ownerId:id,phase:'handoff_wait',coreAlive:false,serviceReady:false});
      return new Promise((_resolve,reject)=>{rejectStart=reject;});},
    command:c=>{assert.equal(c.handoff,true);Object.assign(h.snapshot,{phase:'idle',coreAlive:true,serviceReady:true,coreId:'11-12'});}});
  const owner=await h.client.ensure(()=>{},true,()=>true,'7-8');
  rejectStart(new Error('late SDK receipt'));await turn();
  assert.equal(h.client.pending(),false);assert.equal((await h.client.ensure(()=>{})).coreId,owner.coreId);
  assert.ok(!h.calls.includes('sdkStop'));
});

test('late SDK rejection during acknowledged boot cannot abort the live owner or its ON command',async()=>{
  let available=false,rejectSdk,delays=0;
  const h=clientHarness({read:()=>available?h.snapshot:undefined,
    start:id=>{available=true;Object.assign(h.snapshot,{ownerId:id,phase:'handoff_wait',serviceReady:false,coreAlive:false});
      return new Promise((_resolve,reject)=>{rejectSdk=reject;});},
    command:c=>{
      if(c.handoff){Object.assign(h.snapshot,{phase:'booting',coreAlive:true,coreId:'11-12'});}
      else{Object.assign(h.snapshot,{commandId:c.commandId,connected:c.enabled,phase:c.enabled?'connected':'idle',state:c.enabled?'connected':'disconnected',
        created:c.enabled,processProtected:c.enabled,detached:!c.enabled,destroyed:!c.enabled,attached:c.enabled,ipv4:c.enabled?'100.64.1.1':''});}
    },
    delay:async()=>{delays++;if(delays===1){rejectSdk(new Error('late SDK receipt'));}
      if(delays===2){Object.assign(h.snapshot,{phase:'idle',serviceReady:true});}await turn();}
  });
  const owner=await h.client.ensure(()=>{},true,()=>true,'7-8');assert.equal(owner.coreId,'11-12');
  const connected=await h.client.setEnabled(true,()=>{},()=>true,'7-8');assert.equal(connected.connected,true);
  assert.equal(h.client.pending(),false);assert.ok(!h.calls.includes('sdkStop'));
});

test('an acknowledged stopped actor still fails even when a late receipt is ignored',async()=>{
  let available=false,rejectSdk;
  const h=clientHarness({read:()=>available?h.snapshot:undefined,
    start:id=>{available=true;Object.assign(h.snapshot,{ownerId:id,phase:'handoff_wait',serviceReady:false,coreAlive:false});
      return new Promise((_resolve,reject)=>{rejectSdk=reject;});},
    command:()=>{Object.assign(h.snapshot,{phase:'stopped',error:'boot rejected by owner'});rejectSdk(new Error('late receipt'));}
  });
  await assert.rejects(h.client.ensure(()=>{},true,()=>true,'7-8'),/boot rejected by owner/);
});

function bootPlatformHarness(overrides={}) {
  let alive=false,closes=0,snapshot;
  const monitor={register:cb=>cb({code:9,message:'registration failed'}),unregister:cb=>cb(),on(){},...overrides.monitor};
  const native={startService:async()=>{alive=true;return '{"ok":true}';},
    close:async()=>{closes++;if(overrides.closeFailure){throw new Error('close unconfirmed');}alive=false;return '{"ok":true}';},
    ...overrides.native};
  const platform=compile('vpn/NetworkServicePlatform',{
    '@kit.NetworkKit':{connection:{createNetConnection:()=>monitor}},'@kit.CoreFileKit':{fileIo:{}},'@kit.BasicServicesKit':{},
    '@kit.PerformanceAnalysisKit':{hilog:{warn(){}}},'libtailscale_napi.so':{default:native},
    './NetworkServiceModel':model,'../pages/ClientModel':controls,'./NetworkServiceClient':clients,
    './NetworkServiceStore':{NetworkServiceStore:class{read(){return undefined;}}},'./NetworkEnvironment':{},
    './VpnRecoveryModel':recovery,'../pages/PlatformInfo':{configurePlatformInfo:async()=>{}}
  });
  const port=new platform.PlatformNetworkService({},'/private','same-device');
  port.publish=s=>{snapshot=model.readServiceSnapshot(JSON.stringify(s));};
  return {port,native,alive:()=>alive,closes:()=>closes,snapshot:()=>snapshot};
}

test('listener initialization rejection rolls back only the successfully acquired core',async()=>{
  const h=bootPlatformHarness();await new model.NetworkServiceActor().run(h.port,'1-2');
  assert.equal(h.alive(),false);assert.equal(h.closes(),1);assert.equal(h.snapshot().phase,'stopped');
  assert.match(h.snapshot().error,/registration failed/);
  const rejected=bootPlatformHarness({native:{startService:async()=>'{"ok":false,"error":"account owns state"}'}});
  await new model.NetworkServiceActor().run(rejected.port,'1-2');assert.equal(rejected.closes(),0);
});

test('unconfirmed boot rollback remains cleanup_pending and cannot start a second extension',async()=>{
  const h=bootPlatformHarness({closeFailure:true});await new model.NetworkServiceActor().run(h.port,'1-2');
  assert.equal(h.alive(),true);assert.equal(h.closes(),2);assert.equal(h.snapshot().phase,'cleanup_pending');
  assert.equal(h.snapshot().coreAlive,true);assert.equal(h.snapshot().serviceReady,false);
  const next=clientHarness({read:()=>h.snapshot()});
  await assert.rejects(next.client.ensure(()=>{},true,()=>true,'7-8'),/rollback/);
  assert.ok(!next.calls.includes('sdkStart'));assert.ok(!next.calls.includes('sdkStop'));
});

test('registration timeout rolls back core and unregisters any late successful listener',async t=>{
  t.mock.timers.enable({apis:['setTimeout'],now:1000});let registered,unregisters=0;
  const h=bootPlatformHarness({monitor:{register:cb=>{registered=cb;},unregister:cb=>{unregisters++;cb();}}});
  const run=new model.NetworkServiceActor().run(h.port,'1-2');await until(()=>registered);
  t.mock.timers.tick(10001);await run;assert.equal(h.alive(),false);assert.equal(h.closes(),1);
  const cleaned=unregisters;registered();assert.equal(unregisters,cleaned+1);assert.equal(h.alive(),false);
});

test('status failure after boot cannot report stopped when owned core shutdown is unconfirmed',async()=>{
  const h=bootPlatformHarness({closeFailure:true,monitor:{register:cb=>cb()}});
  h.port.status=async()=>{throw new Error('status unavailable');};
  await new model.NetworkServiceActor().run(h.port,'1-2');
  assert.equal(h.alive(),true);assert.equal(h.closes(),1);assert.equal(h.snapshot().phase,'cleanup_pending');
  assert.equal(h.snapshot().coreAlive,true);assert.match(h.snapshot().error,/status unavailable/);
});

test('confirmed core shutdown clears live network-map readiness from the final valid snapshot',async t=>{
  const h=actorHarness(t);const status=h.port.status;
  h.port.status=async()=>JSON.stringify({...JSON.parse(await status()),networkMapReady:true,assignedIPv4:'100.64.1.1'});
  await until(()=>h.latest()?.networkMapReady);h.actor.cancel();await h.task;
  assert.equal(h.latest().phase,'stopped');assert.equal(h.latest().coreAlive,false);
  assert.equal(h.latest().networkMapReady,false);assert.equal(h.latest().assignedIPv4,'');
});

test('real client and actor complete first ON when the SDK receipt waits for actual VPN creation',async t=>{
  const actor=new model.NetworkServiceActor();let snapshot,command,task,settleSdk;
  let accountOwner=true,attached=false,alive=false;
  const calls=[],intent=Object.assign(new recovery.VpnIntent(),{enabled:true,revision:'7-8'});
  const nativeStatus=async()=>JSON.stringify({...new vpn.VpnState(),coreAlive:alive,coreOwner:alive,coreId:alive?'11-12':'',
    attached,connected:attached,state:attached?'connected':'disconnected',ipv4:attached?'100.64.1.1':'',
    networkMapReady:alive,assignedIPv4:alive?'100.64.1.1':''});
  const actorPort={orphanedNetwork:()=>false,intent:()=>intent,request:()=>command,publish:s=>{snapshot=model.readServiceSnapshot(JSON.stringify(s));},delay:turn,
    boot:async()=>{assert.equal(accountOwner,false);alive=true;calls.push('boot');return '{"ok":true}';},status:nativeStatus,
    create:async()=>{calls.push('create');settleSdk();return 17;},protect:async()=>{calls.push('protect');},
    attach:async()=>{attached=true;calls.push('attach');return '{"ok":true}';},
    detach:async()=>{attached=false;return '{"ok":true}';},closeDescriptor:()=>{},destroy:async()=>{},
    closeCore:async()=>{alive=false;return '{"ok":true}';}};
  const client=new clients.NetworkServiceClient({beginHandoff:()=>{},finishHandoff:()=>{},
    releaseAccount:async()=>{assert.equal(snapshot.phase,'handoff_wait');accountOwner=false;calls.push('release');return '{"ok":true}';},
    start:id=>{calls.push('sdkStart');const receipt=new Promise(resolve=>{settleSdk=resolve;});task=actor.run(actorPort,id,true,'7-8');return receipt;},
    read:()=>snapshot,command:c=>{command=c;},connect:async()=>'{"ok":true}',status:nativeStatus,closeProxy:async()=>'{"ok":true}',delay:turn});
  t.after(async()=>{actor.cancel();settleSdk?.();if(task){await task;}});
  const opening=client.ensure(()=>{},true,()=>true,'7-8');await until(()=>snapshot?.serviceReady);await opening;
  const result=await client.setEnabled(true,()=>{},()=>true,'7-8');assert.equal(result.connected,true);
  assert.deepEqual(calls,['sdkStart','release','boot','create','protect','attach']);
  await client.setEnabled(false,()=>{});assert.equal(snapshot.coreAlive,true);assert.equal(snapshot.connected,false);
});

test('preparation actor ignores wrong generations/revisions and never boots until release acknowledgment',async()=>{
  const actor=new model.NetworkServiceActor();let command,snapshot,boots=0,closes=0;
  const intent=Object.assign(new recovery.VpnIntent(),{enabled:true,revision:'7-8'});
  const port={orphanedNetwork:()=>false,intent:()=>intent,request:()=>command,publish:s=>{snapshot={...s};},delay:turn,
    boot:async()=>{boots++;return '{"ok":true}';},status:async()=>JSON.stringify({...new vpn.VpnState(),coreAlive:true,coreOwner:true,coreId:'11-12'}),
    closeCore:async()=>{closes++;return '{"ok":true}';}};
  const task=actor.run(port,'1-2',true,'7-8');
  await until(()=>snapshot?.phase==='handoff_wait');assert.equal(boots,0);
  command=Object.assign(new model.ServiceCommand(),{ownerId:'9-9',commandId:'3-4',handoff:true,intentId:'7-8'});await turn();await turn();assert.equal(boots,0);
  command.ownerId='1-2';command.intentId='8-9';await turn();await turn();assert.equal(boots,0);
  command.intentId='7-8';await until(()=>snapshot.serviceReady);assert.equal(boots,1);
  actor.cancel();await task;assert.equal(closes,1);
});

test('late authorized actor after cancellation neither touches credentials nor creates a VPN',async()=>{
  const actor=new model.NetworkServiceActor();let snapshot,boots=0,closes=0;
  const intent=Object.assign(new recovery.VpnIntent(),{enabled:false,revision:'9-10'});
  const port={orphanedNetwork:()=>false,intent:()=>intent,request:()=>undefined,publish:s=>{snapshot={...s};},delay:turn,
    boot:async()=>{boots++;return '{"ok":true}';},closeCore:async()=>{closes++;return '{"ok":true}';}};
  await actor.run(port,'1-2',true,'7-8');
  assert.equal(boots,0);assert.equal(closes,0);assert.equal(snapshot.phase,'stopped');assert.equal(snapshot.serviceReady,false);
});

test('failed account release cannot grant the extension access to credential state',async()=>{
  let available=false;
  const h=clientHarness({read:()=>available?h.snapshot:undefined,
    start:async id=>{available=true;Object.assign(h.snapshot,{ownerId:id,phase:'handoff_wait',coreAlive:false,serviceReady:false});},
    releaseAccount:async()=>'{"ok":false,"error":"account shutdown unconfirmed"}'});
  await assert.rejects(h.client.ensure(()=>{},true,()=>true,'7-8'),/unconfirmed/);
  assert.ok(!h.calls.some(Array.isArray));assert.equal(h.snapshot.serviceReady,false);
});

test('rejected extension boot cannot close an existing foreground account owner',async()=>{
  let closed=0,snapshot;
  const actor=new model.NetworkServiceActor();
  const port={orphanedNetwork:()=>false,publish:s=>{snapshot={...s};},
    boot:async()=>'{"ok":false,"error":"account host must release ownership before VPN handoff"}',
    closeCore:async()=>{closed++;return '{"ok":true}';}};
  await actor.run(port,'1-2');assert.equal(closed,0);assert.equal(snapshot.phase,'stopped');assert.match(snapshot.error,/release ownership/);
});

function bootstrapHarness() {
  const files=new Map(),calls=[];
  const fileIo={OpenMode:{CREATE:1,WRITE_ONLY:2,TRUNC:4},openSync:path=>({fd:path}),
    writeSync:(path,value)=>files.set(path,value),closeSync:()=>{},renameSync:(from,to)=>{files.set(to,files.get(from));files.delete(from);},
    accessSync:path=>files.has(path),readTextSync:path=>files.get(path)};
  const stores=compile('vpn/NetworkServiceStore',{'@kit.CoreFileKit':{fileIo},'./NetworkServiceModel':model,'./VpnRecoveryModel':recovery});
  const store=new stores.NetworkServiceStore('/private');
  const abilityModule=compile('vpn/VpnProbeAbility',{
    '@kit.AbilityKit':{},'@kit.NetworkKit':{VpnExtensionAbility:class{},vpnExtension:{createVpnConnection:()=>{calls.push('connection');return {};}}},
    '@kit.CoreFileKit':{fileIo},'@kit.PerformanceAnalysisKit':{hilog:{info(){},error(){}}},'libtailscale_napi.so':{},
    './VpnProbeModel':{VpnProbeController:class{}},'./VpnProbeStore':{},'./VpnSessionModel':{VpnSessionController:class{}},
    './VpnSessionPlatform':{},'./VpnSessionStore':{},'./NetworkServiceModel':{NetworkServiceActor:class{async run(_port,...args){calls.push(['actor',...args]);}}},
    './NetworkServicePlatform':{PlatformNetworkService:class{constructor(_vpn,dir,hostname){calls.push(['port',dir,hostname]);}}},
    './NetworkServiceStore':stores
  });
  const ability=new abilityModule.default();ability.context={filesDir:'/private'};
  const platformModule=compile('vpn/NetworkClientPlatform',{
    '@kit.AbilityKit':{},'@kit.NetworkKit':{vpnExtension:{startVpnExtensionAbility:async want=>{
      assert.equal(store.pendingStart().ownerId,want.parameters.ownerId);calls.push('sdkStart');ability.onCreate({});
    }}},'libtailscale_napi.so':{},'./NetworkServiceClient':clients,'../pages/AccountSessionPlatform':{},
    './NetworkServiceStore':stores,'./NetworkServiceModel':model
  });
  const platform=new platformModule.PlatformNetworkClient({filesDir:'/private'},'same-device');
  store.saveIntent(Object.assign(new recovery.VpnIntent(),{enabled:true,revision:'7-8'}));
  return {store,files,calls,ability,platform};
}

test('first-consent launch with stripped Want parameters uses the persisted current ON request and still waits for handoff',async()=>{
  const h=bootstrapHarness();await h.platform.start('1-2','7-8');await turn();
  assert.deepEqual(h.calls,['sdkStart','connection',['port','/private','same-device'],['actor','1-2',true,'7-8']]);
  assert.equal(h.store.pendingStart().hostname,'same-device');
  assert.equal(h.files.has('/private/network-service-start.json.tmp'),false);
});

test('parameterless startup cannot revive OFF, another revision, expired or already-consumed requests',async t=>{
  t.mock.timers.enable({apis:['Date'],now:100000});
  const h=bootstrapHarness();await h.platform.start('1-2','7-8');h.calls.length=0;
  h.store.saveIntent(Object.assign(new recovery.VpnIntent(),{enabled:false,revision:'9-10'}));h.ability.onCreate({});
  h.store.saveIntent(Object.assign(new recovery.VpnIntent(),{enabled:true,revision:'9-10'}));h.ability.onCreate({});
  h.store.saveIntent(Object.assign(new recovery.VpnIntent(),{enabled:true,revision:'7-8'}));
  t.mock.timers.tick(90001);h.ability.onCreate({});assert.deepEqual(h.calls,[]);
  t.mock.timers.setTime(100000);
  h.store.publish(Object.assign(new model.ServiceSnapshot(),{ownerId:'1-2',phase:'stopped',timestamp:Date.now()}));
  h.ability.onCreate({});assert.deepEqual(h.calls,[]);
});

test('explicit diagnostic mode and malformed pending metadata cannot accidentally start the product service',async()=>{
  const h=bootstrapHarness();await h.platform.start('1-2','7-8');h.calls.length=0;
  h.ability.onCreate({parameters:{vpnMode:'probe'}});assert.deepEqual(h.calls,[]);
  h.files.set('/private/network-service-start.json','invalid');h.ability.onCreate({});assert.deepEqual(h.calls,[]);
  for(const value of [null,{}, {version:1,ownerId:'1-2',intentId:'7-8',hostname:'name\0',timestamp:1000}]){
    assert.throws(()=>model.readServiceStartRequest(JSON.stringify(value)));
  }
});
