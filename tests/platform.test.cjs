'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');
const ts = require(process.env.TYPESCRIPT_MODULE);
function compile(relative, dependencies) {
  const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets', relative + '.ets'), 'utf8');
  const code = ts.transpileModule(source, {compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS}}).outputText;
  const mod = new Module(path.join(__dirname, 'platform-' + path.basename(relative) + '.cjs'), module);
  mod.filename = mod.id; mod.require = id => Object.hasOwn(dependencies, id) ? dependencies[id] : require(id);
  mod._compile(code, mod.filename); return mod.exports;
}
function infoHarness(deviceInfo, configurePlatform = async () => '{"ok":true}') {
  return compile('pages/PlatformInfo', {'@kit.BasicServicesKit':{deviceInfo},'libtailscale_napi.so':{default:{configurePlatform}}});
}
const controls=compile('pages/ClientModel',{});
test('platform info reads the real system version/model without SDK, kernel or unique identifiers', () => {
  const source = {osFullName:'OpenHarmony-6.1.1.120',displayVersion:'product release',productModel:'HUAWEI Mate 70',
    get udid() { throw new Error('must not read UDID'); },get serial() { throw new Error('must not read serial'); }};
  assert.deepEqual({...infoHarness(source).readPlatformInfo()}, {os:'openharmony',osVersion:'6.1.1.120',deviceModel:'HUAWEI Mate 70'});
  assert.deepEqual({...infoHarness({osFullName:'HarmonyOS 6.1.0.117(SP6)',productModel:'test'}).readPlatformInfo()},
    {os:'harmonyos',osVersion:'6.1.0.117(SP6)',deviceModel:'test'});
  assert.equal(infoHarness({displayVersion:'6.1.1.120'}).readPlatformInfo().osVersion, '6.1.1.120');
  const denied = {get osFullName() { throw new Error('denied'); },get displayVersion() { throw new Error('denied'); }};
  assert.deepEqual({...infoHarness(denied).readPlatformInfo()}, {os:'openharmony',osVersion:'',deviceModel:''});
  assert.equal(infoHarness({productModel:'test\0\nphone'}).readPlatformInfo().deviceModel, 'testphone');
});
test('owning extension configures real platform metadata before creating the official core', async () => {
  const calls=[];
  const platformInfo=infoHarness({osFullName:'OpenHarmony-6.1.1.120',productModel:'test-phone'},async raw=>{
    calls.push(['metadata',JSON.parse(raw)]);return '{"ok":true}';
  });
  const {PlatformNetworkService}=compile('vpn/NetworkServicePlatform',{
    '@kit.NetworkKit':{connection:{createNetConnection:()=>({register:cb=>cb(),on(){}})}},
    '@kit.CoreFileKit':{},'@kit.BasicServicesKit':{},'@kit.PerformanceAnalysisKit':{},
    'libtailscale_napi.so':{default:{startService:async()=>{calls.push('start');return '{"ok":true}';}}},
    './NetworkServiceModel':{},'../pages/ClientModel':controls,'./VpnRecoveryModel':{},'./NetworkEnvironment':{},
    './NetworkServiceStore':{NetworkServiceStore:class {read(){}}},
    './NetworkServiceClient':{serviceDeadline:promise=>promise},'../pages/PlatformInfo':platformInfo
  });
  const service=new PlatformNetworkService({},'/private','unchanged-hostname');
  await service.boot();
  assert.deepEqual(calls,[['metadata',{os:'openharmony',osVersion:'6.1.1.120',deviceModel:'test-phone'}],'start']);
  const failed=infoHarness({},async()=>'{"ok":false,"error":"bad metadata"}');
  await assert.rejects(failed.configurePlatformInfo(),/bad metadata/);
});
