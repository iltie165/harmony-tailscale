import { Want } from '@kit.AbilityKit';
import { vpnExtension } from '@kit.NetworkKit';
import { fileIo } from '@kit.CoreFileKit';
import { VpnProbeRequestPort } from './VpnProbeClient';
import { vpnProbePath } from './VpnProbeStore';

export class PlatformVpnProbeRequest implements VpnProbeRequestPort {
  private want: Want;
  private path: string;
  constructor(want: Want, filesDir: string) {
    this.want = want;
    this.path = vpnProbePath(filesDir);
  }
  start(): Promise<void> { return vpnExtension.startVpnExtensionAbility(this.want); }
  stop(): Promise<void> { return vpnExtension.stopVpnExtensionAbility(this.want); }
  read(): string { return fileIo.accessSync(this.path) ? fileIo.readTextSync(this.path) : ''; }
  delay(): Promise<void> {
    return new Promise<void>((resolve) => { setTimeout(resolve, 1000); });
  }
}
