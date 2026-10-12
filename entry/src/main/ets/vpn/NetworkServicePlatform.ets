import { connection, vpnExtension } from '@kit.NetworkKit';
import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import tailscale from 'libtailscale_napi.so';
import { NetworkServicePort, ServiceSnapshot, ServiceCommand, ServiceBlocked, ServiceBootError } from './NetworkServiceModel';
import { readControl } from '../pages/ClientModel';
import { VpnIntent } from './VpnRecoveryModel';
import { inspectNetworks } from './NetworkEnvironment';
import { NetworkServiceStore } from './NetworkServiceStore';
import { serviceDeadline } from './NetworkServiceClient';
import { configurePlatformInfo } from '../pages/PlatformInfo';

export class PlatformNetworkService implements NetworkServicePort {
  private vpn: vpnExtension.VpnConnection;
  private dir: string;
  private hostname: string;
  private store: NetworkServiceStore;
  private monitor: connection.NetConnection | undefined = undefined;
  private closing: boolean = false;
  private orphan: boolean = false;
  constructor(vpn: vpnExtension.VpnConnection, dir: string, hostname: string) {
    this.vpn = vpn;this.dir = dir;this.hostname = hostname;this.store = new NetworkServiceStore(dir);
    try { const previous = this.store.read(); this.orphan = previous !== undefined && previous.created && !previous.destroyed; }
    catch (_error) { throw new Error('网络服务记录损坏，请先在系统设置中关闭本应用 VPN'); }
  }
  orphanedNetwork(): boolean { return this.orphan; }
  async boot(): Promise<string> {
    await configurePlatformInfo();
    const raw: string = await tailscale.startService(`${this.dir}/tailscale`,this.hostname);
    const result = JSON.parse(raw) as CoreResult;
    if (result.ok) {
      try {
        this.monitor = connection.createNetConnection();
        await serviceDeadline(this.monitorOperation(true),10000,'注册网络监听');
        this.monitor.on('netAvailable',() => { this.changed(); });
        this.monitor.on('netLost',() => { this.changed(); });
        this.monitor.on('netConnectionPropertiesChange',() => { this.changed(); });
      } catch (error) {
        // startService success proves this process acquired the native host.
        // Never roll back a rejected start (which may belong to account UI).
        try { readControl(await this.closeCore()); }
        catch (cleanupError) { throw new ServiceBootError(`${error}; core rollback: ${cleanupError}`,true); }
        throw new ServiceBootError(`${error}`,false);
      }
    }
    return raw;
  }
  private changed(): void { if (!this.closing) { tailscale.networkChanged().catch(() => {}); } }
  private monitorOperation(register: boolean): Promise<void> {
    const monitor = this.monitor;
    if (!monitor) { return Promise.resolve(); }
    return new Promise<void>((resolve,reject) => {
      const callback = (error: BusinessError): void => {
        if (error) { reject(new Error(`Network monitor: ${error.code} ${error.message}`)); }
        else {
          // A late registration after timeout/rollback must not leak a listener.
          if (register && this.closing) { monitor.unregister((_error: BusinessError): void => {}); }
          resolve();
        }
      };
      if (register) { monitor.register(callback); } else { monitor.unregister(callback); }
    });
  }
  control(): Promise<string> { return tailscale.getStatus(); }
  status(): Promise<string> { return tailscale.getVpnStatus(); }
  async create(ipv4: string): Promise<number> {
    const environment = await inspectNetworks(ipv4);
    if (environment.otherVpn) { throw new ServiceBlocked('other_vpn', '检测到其他 VPN，请先关闭它，再开启本应用 VPN'); }
    if (!environment.online) { throw new Error('等待物理网络恢复'); }
    try { return await this.vpn.create({
      addresses: [{address:{address:ipv4,family:1},prefixLength:32}],
      routes: [{interface:'',destination:{address:{address:'100.64.0.0',family:1},prefixLength:10},
        gateway:{address:'0.0.0.0',family:1},hasGateway:false,isDefaultRoute:false}],
      mtu:1280,isIPv4Accepted:true,isIPv6Accepted:false,isBlocking:false,
      blockedApplications:['com.ezoo.tailscaleprobe']
    }); } catch (e) {
      const error = e as BusinessError;
      if (error.code === 201 || error.code === 2203001) { throw new ServiceBlocked('authorization_denied', '系统拒绝 VPN 创建，请检查授权'); }
      if (error.code === 2203002) { throw new ServiceBlocked('other_vpn', '系统已有 VPN，停止自动恢复以避免争抢连接'); }
      throw e as Error;
    }
  }
  protect(): Promise<void> { return this.vpn.protectProcessNet(); }
  attach(fd: number, ipv4: string): Promise<string> {
    return tailscale.startVpn(`${this.dir}/tailscale`,this.hostname,ipv4,fd);
  }
  detach(): Promise<string> { return tailscale.detachVpn(); }
  closeDescriptor(fd: number): void { fileIo.closeSync(fd); }
  destroy(): Promise<void> { return this.vpn.destroy(); }
  async closeCore(): Promise<string> {
    this.closing = true;
    try { await serviceDeadline(this.monitorOperation(false),10000,'注销网络监听'); }
    catch (_error) { hilog.warn(0x5453,'TailscaleVPN','Network monitor unregister failed'); }
    finally { this.monitor = undefined; }
    return tailscale.close();
  }
  request(): ServiceCommand | undefined { return this.store.request(); }
  intent(): VpnIntent | undefined { return this.store.intent(); }
  publish(snapshot: ServiceSnapshot): void { this.store.publish(snapshot); }
  delay(): Promise<void> { return new Promise<void>((resolve) => { setTimeout(resolve,500); }); }
}
interface CoreResult { ok: boolean; }
