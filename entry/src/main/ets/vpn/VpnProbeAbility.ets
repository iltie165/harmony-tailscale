import { Want } from '@kit.AbilityKit';
import { vpnExtension, VpnExtensionAbility } from '@kit.NetworkKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import tailscale from 'libtailscale_napi.so';
import { VpnProbeController, VpnProbePort, VpnProbeReport } from './VpnProbeModel';
import { writeVpnProbe } from './VpnProbeStore';

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

  onCreate(want: Want): void {
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
  }

  private async runProbe(requestId: string): Promise<void> {
    try {
      const pending = new VpnProbeReport();
      pending.requestId = requestId;
      pending.stage = 'starting';
      writeVpnProbe(this.context.filesDir, pending);
      const connection = vpnExtension.createVpnConnection(this.context);
      const port = new PlatformVpnProbePort(connection);
      const report = await this.controller.run(port, requestId);
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
