import { ServiceCommand, ServiceSnapshot } from './NetworkServiceModel';
import { VpnState, readVpnState } from './VpnSessionModel';
import { readControl } from '../pages/ClientModel';

export interface NetworkClientPort {
  start(ownerId: string): Promise<void>;
  stop(): Promise<void>;
  read(): ServiceSnapshot | undefined;
  command(value: ServiceCommand): void;
  connect(): Promise<string>;
  status(): Promise<string>;
  closeProxy(): Promise<string>;
  delay(): Promise<void>;
}
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
  private mutation: boolean = false;
  private cancelledEnable: number = 0;
  constructor(port: NetworkClientPort) { this.port = port; }
  pending(): boolean { return this.sdkPending>0 || this.mutation || this.bootstrap !== undefined; }
  cancelEnable(): void {
    this.cancelledEnable++;
    const owner = this.read();
    if (owner?.serviceReady) {
      const c = new ServiceCommand(); c.ownerId = owner.ownerId; c.commandId = nonce();
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
    // Native state is authoritative over a cached connected report.
    if (!live.ok || (s.connected && !live.connected)) {
      s.connected=false;s.state=live.state;s.phase=live.ok?'reconnecting':'error';s.error=live.error;
      s.ok=live.ok;
    }
    return s;
  }
  async ensure(progress: (message:string)=>void): Promise<ServiceSnapshot> {
    if (this.bootstrap) { return this.bootstrap; }
    this.bootstrap=this.initialize(progress);
    try { return await this.bootstrap; } finally { this.bootstrap=undefined; }
  }
  private async initialize(progress: (message:string)=>void): Promise<ServiceSnapshot> {
    if (this.sdkPending>0) { throw new Error('上一次系统操作仍在处理中'); }
    const existing=this.read();
    if (existing && existing.phase==='stopped' && existing.detached && existing.destroyed && existing.descriptorClosed && !existing.coreAlive) {
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
    // Discard only the UI proxy, never the extension owner. The file lease in
    // the native service prevents a second owner if an old process is alive.
    readControl(await this.port.closeProxy());
    progress('正在请求网络服务授权（授权后仍需开启 VPN 开关）…');
    this.sdkPending++;
    const newOwnerId = nonce();
    const start = async (): Promise<void> => { try { await this.port.start(newOwnerId); } finally { this.sdkPending--; } };
    const work = start();
    await serviceDeadline(work,60000,'系统 VPN 服务授权');
    const deadline=Date.now()+30000;
    while (Date.now()<deadline) {
      const s=this.read();
      if (s && fresh(s)) {
        if (s.ownerId===newOwnerId && (s.phase==='stopped'||s.phase==='cleanup_pending')) { throw new Error(s.error||'网络服务启动未完成'); }
        if (s.serviceReady) {
          readControl(await serviceDeadline(this.port.connect(),10000,'连接网络服务'));
          const confirmed=await this.observe();
          if (confirmed?.serviceReady) { return confirmed; }
        }
      }
      await this.port.delay();
    }
    throw new Error('等待网络服务就绪超时，账号记录已保留');
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
      const deadline=Date.now()+35000;
      while (Date.now()<deadline) {
        if (enabled && (!current() || cancellation !== this.cancelledEnable)) { throw new Error('VPN 开启已取消'); }
        const s=this.read();
        if (s && s.ownerId===owner.ownerId && fresh(s)) {
          progress(enabled?'正在连接 VPN…':'正在关闭 VPN…');
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
    } finally {this.mutation=false;}
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
