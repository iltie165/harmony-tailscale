import { vpnExtension, connection } from '@kit.NetworkKit';
import { fileIo } from '@kit.CoreFileKit';
import tailscale from 'libtailscale_napi.so';
import { VpnSessionPort } from './VpnSessionModel';
import { stopRequested } from './VpnSessionStore';
import { boundedVpn } from './VpnSessionClient';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

export class PlatformVpnSession implements VpnSessionPort {
  private connection: vpnExtension.VpnConnection;
  private dir: string;
  private hostname: string;
  private id: string;
  private monitor: connection.NetConnection | undefined = undefined;
  private closing: boolean = false;
  constructor(connection: vpnExtension.VpnConnection, dir: string, hostname: string, id: string) {
    this.connection = connection; this.dir = dir; this.hostname = hostname; this.id = id;
  }
  create(ipv4: string): Promise<number> {
    const config: vpnExtension.VpnConfig = {
      addresses: [{ address: { address: ipv4, family: 1 }, prefixLength: 32 }],
      routes: [{ interface: '', destination: { address: { address: '100.64.0.0', family: 1 }, prefixLength: 10 },
        gateway: { address: '0.0.0.0', family: 1 }, hasGateway: false, isDefaultRoute: false }],
      mtu: 1280, isIPv4Accepted: true, isIPv6Accepted: false, isBlocking: false
    };
    return this.connection.create(config);
  }
  protect(): Promise<void> { return this.connection.protectProcessNet(); }
  async attach(fd: number, ipv4: string): Promise<string> {
    const raw: string = await tailscale.startVpn(`${this.dir}/tailscale`, this.hostname, ipv4, fd);
    const result = JSON.parse(raw) as VpnCoreResult;
    if (result.ok) {
      this.monitor = connection.createNetConnection();
      await boundedVpn<void>(this.monitorOperation(true), 10000, 'Register network monitor');
      this.monitor.on('netAvailable', () => { this.networkChanged(); });
      this.monitor.on('netLost', () => { this.networkChanged(); });
      this.monitor.on('netConnectionPropertiesChange', () => { this.networkChanged(); });
    }
    return raw;
  }
  private monitorOperation(register: boolean): Promise<void> {
    const monitor = this.monitor;
    if (!monitor) { return Promise.resolve(); }
    return new Promise<void>((resolve, reject) => {
      const callback = (error: BusinessError): void => {
        if (error) { reject(new Error(`Network monitor: ${error.code} ${error.message}`)); }
        else { resolve(); }
      };
      if (register) { monitor.register(callback); } else { monitor.unregister(callback); }
    });
  }
  private networkChanged(): void { if (!this.closing) { tailscale.networkChanged().catch(() => {}); } }
  status(): Promise<string> { return tailscale.getVpnStatus(); }
  async closeCore(): Promise<string> {
    this.closing = true;
    try { if (this.monitor) { await boundedVpn<void>(this.monitorOperation(false), 10000, 'Unregister network monitor'); } }
    catch (error) { hilog.warn(0x5453, 'TailscaleVPN', 'Network monitor cleanup: %{public}s', `${error}`); }
    finally { this.monitor = undefined; }
    return tailscale.close();
  }
  closeDescriptor(fd: number): void { fileIo.closeSync(fd); }
  destroy(): Promise<void> { return this.connection.destroy(); }
  stopping(): boolean { return stopRequested(this.dir, this.id); }
  delay(): Promise<void> { return new Promise<void>((resolve) => { setTimeout(resolve, 1000); }); }
}
interface VpnCoreResult { ok: boolean; }
