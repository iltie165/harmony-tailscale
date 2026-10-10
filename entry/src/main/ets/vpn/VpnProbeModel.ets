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

  async run(port: VpnProbePort, requestId: string): Promise<VpnProbeReport> {
    if (this.active) { throw new Error('VPN probe already running'); }
    this.active = true;
    const report = new VpnProbeReport();
    report.requestId = requestId;
    let fd: number = -1;
    try {
      this.checkCancelled();
      report.stage = 'create';
      fd = await port.create();
      report.created = true;
      if (!Number.isInteger(fd) || fd < 0) { throw new Error('VPN returned an invalid descriptor'); }
      this.checkCancelled();
      report.stage = 'protectProcessNet';
      await port.protectProcessNet();
      report.processProtected = true;
      this.checkCancelled();
      report.stage = 'inspectDescriptor';
      const result = JSON.parse(await port.inspect(fd)) as DescriptorResult;
      if (!result || result.ok !== true || result.descriptorValid !== true ||
        result.readWriteDescriptor !== true) {
        throw new Error(result?.error || 'VPN descriptor inspection failed');
      }
      report.descriptorValid = true;
      report.readWriteDescriptor = true;
      this.checkCancelled();
    } catch (error) {
      report.error = `${report.stage}: ${error}`;
    } finally {
      if (report.created) {
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
