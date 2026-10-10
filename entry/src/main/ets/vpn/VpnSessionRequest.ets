import { Want } from '@kit.AbilityKit';
import { vpnExtension } from '@kit.NetworkKit';
import { VpnSessionRequest } from './VpnSessionClient';
import { readSession, requestSessionStop } from './VpnSessionStore';

export class PlatformSessionRequest implements VpnSessionRequest {
  private dir: string;
  private want: Want;
  constructor(dir: string, id: string = '', ipv4: string = '', hostname: string = '') {
    this.dir = dir;
    this.want = { bundleName: 'com.ezoo.tailscaleprobe', abilityName: 'VpnProbeAbility',
      parameters: { vpnMode: 'tailnet', requestId: id, ipv4: ipv4, hostname: hostname } };
  }
  start(): Promise<void> { return vpnExtension.startVpnExtensionAbility(this.want); }
  stop(): Promise<void> { return vpnExtension.stopVpnExtensionAbility(this.want); }
  read(): string { return readSession(this.dir); }
  requestStop(id: string): void { requestSessionStop(this.dir, id); }
  delay(): Promise<void> { return new Promise<void>((resolve) => { setTimeout(resolve, 250); }); }
}
