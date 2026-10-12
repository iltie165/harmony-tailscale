import { common, Want } from '@kit.AbilityKit';
import { vpnExtension } from '@kit.NetworkKit';
import tailscale from 'libtailscale_napi.so';
import { NetworkClientPort } from './NetworkServiceClient';
import { NetworkServiceStore } from './NetworkServiceStore';
import { ServiceCommand, ServiceSnapshot } from './NetworkServiceModel';

export class PlatformNetworkClient implements NetworkClientPort {
  private context: common.UIAbilityContext;
  private hostname: string;
  private store: NetworkServiceStore;
  constructor(context: common.UIAbilityContext, hostname: string) {
    this.context=context;this.hostname=hostname;this.store=new NetworkServiceStore(context.filesDir);
  }
  update(context: common.UIAbilityContext, hostname: string): void { this.context=context;this.hostname=hostname; }
  start(ownerId: string): Promise<void> {
    const want: Want={bundleName:'com.ezoo.tailscaleprobe',abilityName:'VpnProbeAbility',
      parameters:{vpnMode:'service',ownerId:ownerId,hostname:this.hostname}};
    return vpnExtension.startVpnExtensionAbility(want);
  }
  stop(): Promise<void> {
    return vpnExtension.stopVpnExtensionAbility({bundleName:'com.ezoo.tailscaleprobe',abilityName:'VpnProbeAbility'});
  }
  read(): ServiceSnapshot | undefined { return this.store.read(); }
  command(value: ServiceCommand): void { this.store.command(value); }
  connect(): Promise<string> { return tailscale.connectService(`${this.context.filesDir}/tailscale`,this.hostname); }
  status(): Promise<string> { return tailscale.getVpnStatus(); }
  closeProxy(): Promise<string> { return tailscale.disconnectClient(); }
  delay(): Promise<void> { return new Promise<void>((resolve) => { setTimeout(resolve,250); }); }
}
