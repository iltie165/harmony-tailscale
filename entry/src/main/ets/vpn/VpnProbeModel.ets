// Platform capabilities are distinct from a working Tailnet data path.
export class VpnProbeReport {
  requestId: string = '';
  ok: boolean = false;
  mode: string = 'capability-only';
  tunnelConnected: boolean = false;
  stage: string = 'idle';
  created: boolean = false;
  descriptorValid: boolean = false;
  readWriteDescriptor: boolean = false;
  descriptorInspection: string = '';
  warning: string = '';
  packetIOVerified: boolean = false;
  processProtected: boolean = false;
  descriptorClosed: boolean = false;
  destroyed: boolean = false;
  error: string = '';
}

export interface VpnProbePort {
  create(): Promise<number>;
  protectProcessNet(): Promise<void>;
  inspect(fd: number): Promise<string>;
  close(fd: number): void;
  destroy(): Promise<void>;
}

interface DescriptorResult {
  ok: boolean;
  descriptorValid: boolean;
  readWriteDescriptor: boolean;
  error?: string;
  warning?: string;
  packetIOVerified?: boolean;
}

export function readVpnProbe(raw: string, requestId: string): VpnProbeReport {
  const report = JSON.parse(raw) as VpnProbeReport;
  if (!report || report.requestId !== requestId || report.mode !== 'capability-only' ||
    report.tunnelConnected !== false || typeof report.ok !== 'boolean' ||
    typeof report.stage !== 'string' || typeof report.error !== 'string' ||
    typeof report.created !== 'boolean' || typeof report.descriptorValid !== 'boolean' ||
    typeof report.readWriteDescriptor !== 'boolean' || typeof report.processProtected !== 'boolean' ||
    typeof report.descriptorClosed !== 'boolean' || typeof report.destroyed !== 'boolean') {
    throw new Error('Invalid VPN capability report');
  }
  if (report.descriptorInspection !== undefined && typeof report.descriptorInspection !== 'string') {
    throw new Error('Invalid descriptor inspection details');
  }
  if ((report.warning !== undefined && typeof report.warning !== 'string') ||
    (report.packetIOVerified !== undefined && report.packetIOVerified !== false)) {
    throw new Error('Invalid VPN capability verification boundary');
  }
  if (report.ok && (report.stage !== 'complete' || !report.created || !report.descriptorValid ||
    !report.readWriteDescriptor || !report.processProtected || !report.descriptorClosed ||
    !report.destroyed || report.error !== '')) {
    throw new Error('Incomplete VPN capability report');
  }
  return report;
}

export class VpnProbeController {
  private cancelled: boolean = false;
  private active: boolean = false;

  cancel(): void { this.cancelled = true; }

  private checkCancelled(): void {
    if (this.cancelled) { throw new Error('VPN probe cancelled by extension lifecycle'); }
  }

  async run(port: VpnProbePort, requestId: string,
    progress: (report: VpnProbeReport) => void = () => {}): Promise<VpnProbeReport> {
    if (this.active) { throw new Error('VPN probe already running'); }
    this.active = true;
    const report = new VpnProbeReport();
    report.requestId = requestId;
    let fd: number = -1;
    try {
      this.checkCancelled();
      report.stage = 'create';
      progress(report);
      fd = await port.create();
      report.created = true;
      if (!Number.isInteger(fd) || fd < 0) { throw new Error('VPN returned an invalid descriptor'); }
      this.checkCancelled();
      report.stage = 'protectProcessNet';
      progress(report);
      await port.protectProcessNet();
      report.processProtected = true;
      this.checkCancelled();
      report.stage = 'inspectDescriptor';
      progress(report);
      report.descriptorInspection = await port.inspect(fd);
      const result = JSON.parse(report.descriptorInspection) as DescriptorResult;
      if (!result || typeof result.ok !== 'boolean' || typeof result.descriptorValid !== 'boolean' ||
        typeof result.readWriteDescriptor !== 'boolean') {
        throw new Error('Invalid native descriptor inspection result');
      }
      // Preserve successful measurements even when a later candidate check fails.
      report.descriptorValid = result.descriptorValid;
      report.readWriteDescriptor = result.readWriteDescriptor;
      if ((result.warning !== undefined && typeof result.warning !== 'string') ||
        (result.packetIOVerified !== undefined && result.packetIOVerified !== false)) {
        throw new Error('Invalid native packet verification claim');
      }
      report.warning = result.warning || '';
      if (!result.ok || !result.descriptorValid || !result.readWriteDescriptor) {
        throw new Error(result?.error || 'VPN descriptor inspection failed');
      }
      this.checkCancelled();
    } catch (error) {
      report.error = `${report.stage}: ${error}`;
    } finally {
      if (report.created) {
        report.stage = 'cleanup';
        // Reporting failure must not prevent descriptor/connection cleanup.
        try { progress(report); }
        catch (error) { report.error += `; reportProgress: ${error}`; }
        // Our descriptor is closed before destroying the platform connection.
        // Native inspection only borrows it and closes its own duplicate.
        if (Number.isInteger(fd) && fd >= 0) {
          try { port.close(fd); report.descriptorClosed = true; }
          catch (error) { report.error += `; closeDescriptor: ${error}`; }
        }
        try { await port.destroy(); report.destroyed = true; }
        catch (error) { report.error += `; destroy: ${error}`; }
      }
      report.ok = report.created && report.descriptorValid && report.readWriteDescriptor &&
        report.processProtected && report.descriptorClosed && report.destroyed && !report.error;
      report.stage = report.ok ? 'complete' : 'failed';
      this.active = false;
    }
    return report;
  }
}
