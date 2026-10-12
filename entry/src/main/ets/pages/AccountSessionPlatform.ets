import { connection } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import tailscale from 'libtailscale_napi.so';
import { readControl } from './ClientModel';
import { configurePlatformInfo } from './PlatformInfo';
import { serviceDeadline } from '../vpn/NetworkServiceClient';
import { readVpnState } from '../vpn/VpnSessionModel';

// App-runtime account host: no vpnExtension import, authorization or vNIC.
export class AccountSessionPlatform {
  private task: Promise<void> | undefined = undefined;
  private monitor: connection.NetConnection | undefined = undefined;
  private transferring: boolean = false;
  beginHandoff(): void { this.transferring = true; }
  finishHandoff(): void { this.transferring = false; }
  async ensure(dir: string, hostname: string): Promise<void> {
    if (this.transferring) { throw new Error('网络服务正在转交，稍后重试同步'); }
    if (this.task) { return this.task; }
    this.task = this.start(dir, hostname);
    try { await this.task; } finally { this.task = undefined; }
  }
  private async start(dir: string, hostname: string): Promise<void> {
    const live = readVpnState(await tailscale.getVpnStatus());
    if (!live.coreAlive) { await configurePlatformInfo(); }
    if (this.transferring) { throw new Error('网络服务正在转交'); }
    readControl(await tailscale.startAccount(dir, hostname));
    const owner = readVpnState(await tailscale.getVpnStatus());
    if(!owner.ok || !owner.coreAlive){throw new Error(owner.error || '账号核心尚未就绪');}
    if (owner.coreHost === 'account' && !this.monitor) {
      const monitor = connection.createNetConnection();
      let abandoned: boolean = false;
      const registration: Promise<void> = new Promise<void>((resolve, reject) => {
        monitor.register((error: BusinessError): void => {
          if (error) { reject(new Error(`网络监听：${error.code} ${error.message}`)); }
          else {
            if(abandoned){monitor.unregister((_error:BusinessError):void=>{});}
            resolve();
          }
        });
      });
      try{await serviceDeadline<void>(registration,10000,'注册账号网络监听');}
      catch(e){abandoned=true;throw e as Error;}
      this.monitor = monitor;
      monitor.on('netAvailable', () => { this.changed(); });
      monitor.on('netLost', () => { this.changed(); });
      monitor.on('netConnectionPropertiesChange', () => { this.changed(); });
    }
  }
  private changed(): void { tailscale.networkChanged().catch(() => {}); }
  async release(): Promise<string> {
    if (this.task) { await this.task; }
    const result: string = await tailscale.releaseAccount();
    readControl(result);
    await this.stopMonitor();
    return result;
  }
  async stopMonitor(): Promise<void> {
    const monitor = this.monitor; this.monitor = undefined;
    if (monitor) {
      await serviceDeadline<void>(new Promise<void>((resolve) => {
        monitor.unregister((_error: BusinessError): void => { resolve(); });
      }),3000,'停止账号网络监听');
    }
  }
}
const accountSession = new AccountSessionPlatform();
export function getAccountSession(): AccountSessionPlatform { return accountSession; }
