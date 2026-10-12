import { Want } from '@kit.AbilityKit';
import { vpnExtension, VpnExtensionAbility } from '@kit.NetworkKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import tailscale from 'libtailscale_napi.so';
import { VpnProbeController, VpnProbePort, VpnProbeReport } from './VpnProbeModel';
import { writeVpnProbe } from './VpnProbeStore';
import { VpnSessionController, VpnSessionReport } from './VpnSessionModel';
import { PlatformVpnSession } from './VpnSessionPlatform';
import { publishSession } from './VpnSessionStore';
import { NetworkServiceActor } from './NetworkServiceModel';
import { PlatformNetworkService } from './NetworkServicePlatform';
import { NetworkServiceStore } from './NetworkServiceStore';

class PlatformVpnProbePort implements VpnProbePort {
  private connection: vpnExtension.VpnConnection;
  constructor(connection: vpnExtension.VpnConnection) { this.connection = connection; }
  create(): Promise<number> {
    const config: vpnExtension.VpnConfig = {
      addresses: [{ address: { address: '192.0.2.1', family: 1 }, prefixLength: 32 }],
      routes: [], mtu: 1280, isIPv4Accepted: true, isIPv6Accepted: false
    };
    return this.connection.create(config);
  }
  protectProcessNet(): Promise<void> { return this.connection.protectProcessNet(); }
  inspect(fd: number): Promise<string> { return tailscale.inspectVpnDescriptor(fd); }
  close(fd: number): void { fileIo.closeSync(fd); }
  destroy(): Promise<void> { return this.connection.destroy(); }
}

// Diagnostic only: no default route, Tailnet route, DNS override or core startup.
export default class VpnProbeAbility extends VpnExtensionAbility {
  private controller: VpnProbeController = new VpnProbeController();
  private session: VpnSessionController = new VpnSessionController();
  private service: NetworkServiceActor = new NetworkServiceActor();

  onCreate(want: Want): void {
    // SDK: first-consent Want.parameters delivery is supported from API 22.
    // Authorization creates the extension, but it need not preserve our Want.
    // Only an unconsumed, current explicit ON may use the private fallback.
    if (want.parameters?.vpnMode === undefined && want.parameters?.probeRequestId === undefined && want.parameters?.requestId === undefined) {
      try {
        const request = new NetworkServiceStore(this.context.filesDir).pendingStart();
        if (request) {
          this.runService({bundleName:'com.ezoo.tailscaleprobe',abilityName:'VpnProbeAbility',
            parameters:{vpnMode:'service',ownerId:request.ownerId,hostname:request.hostname,prepareOnly:true,intentId:request.intentId}});
          return;
        }
      } catch (_error) { hilog.error(0x5453,'TailscaleVPN','Invalid or unavailable pending VPN start request'); }
    }
    if (want.parameters?.vpnMode === 'service') {
      this.runService(want); return;
    }
    if (want.parameters?.vpnMode === 'tailnet') {
      this.runSession(want);
      return;
    }
    const requestId = want.parameters?.probeRequestId;
    if (typeof requestId !== 'string' || !/^[0-9-]{1,80}$/.test(requestId)) {
      hilog.error(0x5453, 'VpnCapabilityProbe', 'Missing diagnostic request identifier');
      return;
    }
    this.runProbe(requestId);
  }

  onDestroy(): void {
    // Do not race destroy against an outstanding create/protect/inspection.
    // The controller checks cancellation after each await and always cleans up.
    this.controller.cancel();
    this.session.cancel();
    this.service.cancel();
  }

  private async runService(want: Want): Promise<void> {
    const ownerId = want.parameters?.ownerId;
    const hostname = want.parameters?.hostname;
    if (typeof ownerId !== 'string' || !/^[0-9-]{1,80}$/.test(ownerId) || typeof hostname !== 'string') {
      hilog.error(0x5453,'TailscaleVPN','Invalid network service bootstrap');return;
    }
    try {
      hilog.info(0x5453,'TailscaleVPN','Authorized extension started; awaiting account handoff');
      const port = new PlatformNetworkService(vpnExtension.createVpnConnection(this.context),this.context.filesDir,hostname);
      await this.service.run(port,ownerId,want.parameters?.prepareOnly === true,
        typeof want.parameters?.intentId === 'string' ? want.parameters.intentId : '');
    } catch (_error) { hilog.error(0x5453,'TailscaleVPN','Network service actor terminated'); }
  }

  private async runSession(want: Want): Promise<void> {
    const id = want.parameters?.requestId;
    const ipv4 = want.parameters?.ipv4;
    const hostname = want.parameters?.hostname;
    if (typeof id !== 'string' || !/^[0-9-]{1,80}$/.test(id) || typeof ipv4 !== 'string' || typeof hostname !== 'string') {
      hilog.error(0x5453, 'TailscaleVPN', 'Invalid VPN startup parameters'); return;
    }
    try {
      const port = new PlatformVpnSession(vpnExtension.createVpnConnection(this.context), this.context.filesDir, hostname, id);
      await this.session.run(port, id, ipv4, (report: VpnSessionReport) => {
        publishSession(this.context.filesDir, report);
      });
    } catch (error) {
      const report = new VpnSessionReport(); report.requestId = id; report.stage = 'failed';
      report.ok = false; report.state = 'error'; report.error = `VPN service: ${error}`;
      try { publishSession(this.context.filesDir, report); } catch (_storeError) {}
      hilog.error(0x5453, 'TailscaleVPN', '%{public}s', report.error);
    }
  }

  private async runProbe(requestId: string): Promise<void> {
    try {
      const pending = new VpnProbeReport();
      pending.requestId = requestId;
      pending.stage = 'starting';
      writeVpnProbe(this.context.filesDir, pending);
      const connection = vpnExtension.createVpnConnection(this.context);
      const port = new PlatformVpnProbePort(connection);
      const report = await this.controller.run(port, requestId, (current: VpnProbeReport) => {
        writeVpnProbe(this.context.filesDir, current);
        hilog.info(0x5453, 'VpnCapabilityProbe', 'Probe stage: %{public}s', current.stage);
      });
      writeVpnProbe(this.context.filesDir, report);
      hilog.info(0x5453, 'VpnCapabilityProbe', 'Capability-only result: %{public}s', JSON.stringify(report));
    } catch (error) {
      const report = new VpnProbeReport();
      report.requestId = requestId;
      report.stage = 'failed';
      report.error = `VPN extension probe: ${error}`;
      try { writeVpnProbe(this.context.filesDir, report); }
      catch (storeError) { hilog.error(0x5453, 'VpnCapabilityProbe', 'Cannot persist probe report'); }
      hilog.error(0x5453, 'VpnCapabilityProbe', '%{public}s', report.error);
    }
  }
}
