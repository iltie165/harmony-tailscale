import { ServiceCommand, ServiceSnapshot } from './NetworkServiceModel';
import { VpnState, readVpnState } from './VpnSessionModel';
import { readControl } from '../pages/ClientModel';

export interface NetworkClientPort {
  start(ownerId: string, intentId?: string): Promise<void>;
  stop(): Promise<void>;
  beginHandoff(): void;
  finishHandoff(): void;
  releaseAccount(): Promise<string>;
  read(): ServiceSnapshot | undefined;
  command(value: ServiceCommand): void;
  connect(): Promise<string>;
  status(): Promise<string>;
  closeProxy(): Promise<string>;
  delay(): Promise<void>;
}
export class VpnAuthorizationRequired extends Error {}
export class NetworkServiceError extends Error {
  cleanupConfirmed: boolean;
  constructor(message: string, confirmed: boolean) { super(message);this.cleanupConfirmed=confirmed; }
}
export function serviceDeadline<T>(work: Promise<T>, milliseconds: number, label: string): Promise<T> {
  return new Promise<T>((resolve,reject) => {
    const timer = setTimeout(() => { reject(new Error(`${label}超时`)); },milliseconds);
    work.then((result:T) => {clearTimeout(timer);resolve(result);},(error:Error) => {clearTimeout(timer);reject(error);});
  });
}
export function cancellableService<T>(work: Promise<T>, current: () => boolean, milliseconds: number, label: string): Promise<T> {
  return new Promise<T>((resolve,reject) => {
    const end = Date.now()+milliseconds;
    const check = setInterval(() => {
      if (!current() || Date.now()>=end) {
        clearInterval(check); reject(new Error(!current() ? 'VPN 开启已取消' : `${label}超时`));
      }
    },100);
    work.then((value:T)=>{clearInterval(check);resolve(value);},(e:Error)=>{clearInterval(check);reject(e);});
  });
}
function fresh(snapshot: ServiceSnapshot): boolean {
  const age = Date.now()-snapshot.timestamp;
  return age >= -1000 && age <= 20000;
}
function nonce(): string { return `${Date.now()}-${Math.floor(Math.random()*1000000000)}`; }

// One client per application runtime. The actor owns core/TUN/SDK resources;
// this client verifies owner generation and serializes user intents. Disposing
// a page observer does not cancel an accepted VPN command.
export class NetworkServiceClient {
  private port: NetworkClientPort;
  private bootstrap: Promise<ServiceSnapshot> | undefined = undefined;
  private sdkPending: number = 0;
  private connectDeadline: number = 0;
  private mutation: boolean = false;
  private cancelledEnable: number = 0;
  constructor(port: NetworkClientPort) { this.port = port; }
  pending(): boolean { return this.sdkPending>0 || this.mutation || this.bootstrap !== undefined; }
  cancelEnable(): void {
    this.cancelledEnable++;
    const owner = this.read();
    if (owner && (owner.serviceReady || owner.phase === 'handoff_wait')) {
      const c = new ServiceCommand(); c.ownerId = owner.ownerId; c.commandId = nonce(); c.shutdown = !owner.serviceReady;
      this.port.command(c);
    }
  }
  private read(): ServiceSnapshot | undefined {
    try { return this.port.read(); } catch (_error) { return undefined; }
  }
  async observe(): Promise<ServiceSnapshot | undefined> {
    const s = this.read();
    if (!s) { return undefined; }
    if (s.phase==='stopped' && fresh(s) && s.detached && s.destroyed && s.descriptorClosed && !s.coreAlive) { return s; }
    if (!s.serviceReady) { throw new NetworkServiceError('网络服务状态待确认，请检查系统 VPN 状态',s.detached&&s.destroyed&&s.descriptorClosed); }
    const live = readVpnState(await serviceDeadline(this.port.status(),5000,'读取核心健康状态'));
    if (!live.coreAlive || live.coreId!==s.coreId) { throw new NetworkServiceError('网络服务实例已变化，请重新连接',false); }
    if (!fresh(s)) { throw new NetworkServiceError('核心仍在运行，但服务响应超时；请检查系统 VPN 状态',false); }
    s.networkMapReady = live.networkMapReady === true;
    s.assignedIPv4 = live.assignedIPv4 || '';
    // Native state is authoritative over a cached connected report.
    if (!live.ok || (s.connected && !live.connected)) {
      s.connected=false;s.state=live.state;s.phase=live.ok?'reconnecting':'error';s.error=live.error;
      s.ok=live.ok;
    }
    return s;
  }
  async ensure(progress: (message:string)=>void, authorize: boolean = false,
    current: () => boolean = (): boolean => true, intentId: string = ''): Promise<ServiceSnapshot> {
    if (this.bootstrap) { return this.bootstrap; }
    this.bootstrap=this.initialize(progress,authorize,current,intentId);
    try { return await this.bootstrap; } finally { this.bootstrap=undefined; }
  }
  private async initialize(progress: (message:string)=>void, authorize: boolean,
    current: () => boolean, intentId: string): Promise<ServiceSnapshot> {
    if (this.sdkPending>0) { throw new Error('上一次系统操作仍在处理中'); }
    if(authorize){this.connectDeadline=0;}
    const existing=this.read();
    if (authorize && existing && existing.phase==='stopped' && existing.detached && existing.destroyed && existing.descriptorClosed && !existing.coreAlive) {
      this.sdkPending++;
      const stop = async (): Promise<void> => { try { await this.port.stop(); } finally { this.sdkPending--; } };
      await serviceDeadline(stop(),10000,'清理已停止的服务');
    }
    if (existing && existing.serviceReady) {
      progress('正在连接已有网络服务…');
      let healthyCore = false;
      try {
        readControl(await serviceDeadline(this.port.connect(),10000,'连接已有服务'));
        const live = readVpnState(await serviceDeadline(this.port.status(),5000,'检查已有核心'));
        healthyCore = live.coreAlive;
        if (!live.coreAlive && live.coreId === existing.coreId) {
          // Only a confirmed dead engine permits stopping the old host. A
          // control-plane outage or a stale heartbeat alone never does.
          this.sdkPending++;
          const stop = async (): Promise<void> => { try { await this.port.stop(); } finally { this.sdkPending--; } };
          await serviceDeadline(stop(),10000,'清理已停止的服务');
        } else {
          const confirmed=await this.observe();
          if (!confirmed || !confirmed.serviceReady) { throw new Error('已有网络服务未就绪'); }
          return confirmed;
        }
      } catch (e) { if (healthyCore || this.sdkPending>0) { throw e as Error; } }
    }
    if (!authorize) { throw new VpnAuthorizationRequired('需要点击开启 VPN，授权并启动网络服务'); }
    if (!current()) { throw new Error('VPN 开启已取消'); }
    // Discard only the UI proxy, never the extension owner. The file lease in
    // the native service prevents a second owner if an old process is alive.
    readControl(await this.port.closeProxy());
    this.port.beginHandoff();
    try {
      progress('请在系统提示中允许 VPN…');
      this.sdkPending++;
      const newOwnerId = nonce();
      const start = async (): Promise<void> => { try { await this.port.start(newOwnerId,intentId); } finally { this.sdkPending--; } };
      await cancellableService(start(),current,60000,'等待系统 VPN 授权');
      const deadline=Date.now()+30000;this.connectDeadline=deadline;
      let lastConnectionError = '';
      let released = false;
      while (Date.now()<deadline) {
        if (!current()) { throw new Error('VPN 开启已取消'); }
        const s=this.read();
        if (s && s.ownerId===newOwnerId && fresh(s)) {
          if (s.phase==='stopped'||s.phase==='cleanup_pending') { throw new Error(s.error||'网络服务启动未完成'); }
          if (s.phase==='handoff_wait' && !released) {
            progress('正在准备 VPN 服务…');
            readControl(await serviceDeadline(this.port.releaseAccount(),10000,'转交账号服务'));
            if (!current()) { throw new Error('VPN 开启已取消'); }
            const c = new ServiceCommand(); c.ownerId=newOwnerId; c.commandId=nonce();c.handoff=true;c.intentId=intentId;
            this.port.command(c); released=true;
          }
          if (s.serviceReady) {
            try { readControl(await serviceDeadline(this.port.connect(),5000,'连接本地 VPN 服务')); }
            catch (e) { lastConnectionError=`${e}`;await this.port.delay();continue; }
            const confirmed=await this.observe();
            if (confirmed?.serviceReady) { return confirmed; }
          }
        }
        await this.port.delay();
      }
      throw new Error(`本地 VPN 服务启动超时${lastConnectionError ? `：${lastConnectionError}` : ''}`);
    } finally { this.port.finishHandoff(); }
  }

  async setEnabled(enabled:boolean,progress:(message:string)=>void,
    current: () => boolean = (): boolean => true, intentId: string = '', repair: boolean = false): Promise<ServiceSnapshot> {
    if (this.mutation) { throw new Error('网络操作正在处理中'); }
    this.mutation=true;
    const cancellation = this.cancelledEnable;
    let command: ServiceCommand | undefined = undefined;
    try {
      let owner=enabled?await this.ensure(progress):await this.observe();
      if (enabled && (!current() || cancellation !== this.cancelledEnable)) { throw new Error('VPN 开启已取消'); }
      if (!owner) { throw new NetworkServiceError('无法确认 VPN 所属服务，请在系统设置中检查',false); }
      if (!enabled && owner.detached && owner.destroyed && owner.descriptorClosed) { return owner; }
      command=new ServiceCommand();command.ownerId=owner.ownerId;command.commandId=nonce();command.enabled=enabled;
      command.intentId = intentId; command.repair = repair;
      this.port.command(command);
      const deadline=enabled&&this.connectDeadline ? Math.min(Date.now()+30000,this.connectDeadline) : Date.now()+30000;
      while (Date.now()<deadline) {
        if (enabled && (!current() || cancellation !== this.cancelledEnable)) { throw new Error('VPN 开启已取消'); }
        const s=this.read();
        if (s && s.ownerId===owner.ownerId && fresh(s)) {
          progress(!enabled ? '正在关闭 VPN…' : s.phase === 'waiting_core' ? '正在获取本机网络配置…' :
            s.phase === 'create' ? '正在创建 VPN 网卡…' : s.phase === 'protect' || s.phase === 'attach' ? '正在建立 VPN 连接…' : '正在确认 VPN 状态…');
          if (s.commandId===command.commandId) {
            if (s.phase==='error'||s.phase==='cleanup_pending'||s.phase==='stopped') {
              throw new NetworkServiceError(s.error||'网络服务已停止',s.detached&&s.destroyed&&s.descriptorClosed);
            }
            if (enabled && s.connected) { const live=await this.observe();if(live?.connected){return live;} }
            if (!enabled && s.detached&&s.destroyed&&s.descriptorClosed&&s.phase==='idle') { return s; }
          }
        }
        await this.port.delay();
      }
      throw new NetworkServiceError('VPN 操作超时，请检查系统 VPN 状态',false);
    } catch(e) {
      // Cancel a timed-out ON intent; late native/SDK completion must not leave
      // an unwanted interface enabled. The actor checks this after each await.
      if (enabled && command && cancellation === this.cancelledEnable) {
        const cancel=new ServiceCommand();cancel.ownerId=command.ownerId;cancel.commandId=nonce();
        this.port.command(cancel);
      }
      throw e as Error;
    } finally {this.mutation=false;this.connectDeadline=0;}
  }
  async shutdown(): Promise<void> {
    if(this.mutation||this.sdkPending>0){throw new Error('网络操作正在处理中');}
    this.mutation=true;
    try {
      const owner=this.read();
      if(!owner||!fresh(owner)){throw new NetworkServiceError('无法确认网络服务清理，请检查系统 VPN',false);}
      const c=new ServiceCommand();c.ownerId=owner.ownerId;c.commandId=nonce();c.shutdown=true;
      this.port.command(c);
      const deadline=Date.now()+30000;
      while(Date.now()<deadline){
        const s=this.read();
        if(s && s.ownerId===owner.ownerId && fresh(s) && s.phase==='stopped' && s.detached&&s.destroyed&&s.descriptorClosed&&!s.coreAlive){
          this.sdkPending++;
          const stop = async (): Promise<void> => { try { await this.port.stop(); } finally { this.sdkPending--; } };
          await serviceDeadline(stop(),10000,'停止网络服务扩展');
          readControl(await this.port.closeProxy());return;
        }
        await this.port.delay();
      }
      throw new NetworkServiceError('网络服务清理超时',false);
    } finally{this.mutation=false;}
  }
}
