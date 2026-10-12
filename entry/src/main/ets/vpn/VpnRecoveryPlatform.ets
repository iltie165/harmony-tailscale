import tailscale from 'libtailscale_napi.so';
import { readControl, isAuthenticated } from '../pages/ClientModel';
import { NetworkServiceClient, VpnAuthorizationRequired, serviceDeadline } from './NetworkServiceClient';
import { PlatformNetworkClient } from './NetworkClientPlatform';
import { NetworkServiceStore } from './NetworkServiceStore';
import { readVpnState } from './VpnSessionModel';
import { ServiceSnapshot } from './NetworkServiceModel';
import { inspectNetworks } from './NetworkEnvironment';
import { VpnIntent, VpnRecoveryPort, RecoveryReport, RecoveryBlocked } from './VpnRecoveryModel';

export class PlatformVpnRecovery implements VpnRecoveryPort {
  private client: NetworkServiceClient;
  private platform: PlatformNetworkClient;
  private store: NetworkServiceStore;
  private onState: (snapshot: ServiceSnapshot) => void;
  private onReport: (report: RecoveryReport) => void;
  constructor(client: NetworkServiceClient, platform: PlatformNetworkClient, dir: string,
    onState: (snapshot: ServiceSnapshot) => void, onReport: (report: RecoveryReport) => void) {
    this.client = client; this.platform = platform; this.store = new NetworkServiceStore(dir);
    this.onState = onState; this.onReport = onReport;
  }
  readIntent(): VpnIntent | undefined { return this.store.intent(); }
  writeIntent(value: VpnIntent): void { this.store.saveIntent(value); }
  cancel(): void { this.client.cancelEnable(); }
  async disconnect(): Promise<void> {
    const cached = this.platform.read();
    if (!cached || !cached.serviceReady) {
      const live = readVpnState(await tailscale.getVpnStatus());
      if (!live.attached && (live.coreHost === 'account' || !live.coreAlive)) { return; }
      if (cached?.phase === 'stopped' && cached.detached && cached.destroyed && cached.descriptorClosed) { return; }
    }
    this.onState(await this.client.setEnabled(false, (_message: string): void => {}));
  }
  publish(report: RecoveryReport): void { this.onReport(report); }
  async recover(intent: VpnIntent, current: () => boolean, progress: (message: string) => void, manual: boolean = false): Promise<void> {
    if (!current() || this.client.pending()) { throw new Error('等待当前网络操作完成'); }
    const cached = this.platform.read();
    const environment = await inspectNetworks(cached?.ipv4 || '');
    if (!current()) { return; }
    if (environment.otherVpn) { throw new RecoveryBlocked('检测到其他 VPN，自动恢复已暂停；请确认后重新开启'); }
    if (!environment.online) { throw new Error('等待物理网络恢复'); }
    let owner: ServiceSnapshot;
    try { owner = await this.client.ensure(progress,manual,current,intent.revision); }
    catch (e) {
      if (e instanceof VpnAuthorizationRequired) { throw new RecoveryBlocked('VPN 服务已停止，请点击开启 VPN 重新连接'); }
      throw e as Error;
    }
    if (!current()) { return; }
    if (!environment.ownVpn) { owner.connected = false; }
    this.onState(owner);
    // A temporary control outage with an intact data path needs no teardown.
    if (owner.connected && environment.ownVpn) { return; }
    if (!owner.networkMapReady) {
      const control = readControl(await serviceDeadline(tailscale.getStatus(), 5000, '核对本地账号状态'));
      if (!current()) { return; }
      if (!isAuthenticated(control)) { throw new RecoveryBlocked('账号需要重新认证，自动恢复已暂停'); }
    }
    // Native attached + OS interface missing requires explicit repair. Merely
    // reconnecting to the control server must never destroy an intact TUN.
    if (owner.attached && environment.ownVpn && owner.ok) { throw new Error('原核心正在恢复连接'); }
    try {
      const repaired = await this.client.setEnabled(true, progress, current, intent.revision,
        owner.attached && !environment.ownVpn);
      if (current()) {
        const confirmed = await inspectNetworks(repaired.ipv4);
        if (!current()) { return; }
        if (!confirmed.ownVpn || confirmed.otherVpn) {
          repaired.connected = false; this.onState(repaired);
          if (confirmed.otherVpn) { throw new RecoveryBlocked('VPN 连接已被其他 VPN 替换，自动恢复已暂停'); }
          throw new Error('系统尚未确认 VPN 网卡，继续检查恢复状态');
        }
        this.onState(repaired);
      }
    } catch (e) {
      const failed = this.platform.read();
      if (failed?.stopReason === 'authentication_required' || failed?.stopReason === 'authorization_denied' || failed?.stopReason === 'other_vpn') {
        throw new RecoveryBlocked(failed.error || '需要用户处理后重新开启 VPN');
      }
      throw e as Error;
    }
  }
}
