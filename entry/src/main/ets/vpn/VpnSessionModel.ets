export class VpnState {
  ok: boolean = true;
  connected: boolean = false;
  state: string = 'disconnected';
  ipv4: string = '';
  txPackets: number = 0;
  rxPackets: number = 0;
  txBytes: number = 0;
  rxBytes: number = 0;
  error: string = '';
  debugLogs: string[] = [];
  coreId: string = '';
  coreHost: string = '';
  coreAlive: boolean = false;
  coreOwner: boolean = false;
  attached: boolean = false;
  startedAt: number = 0;
  networkMapReady: boolean = false;
  assignedIPv4: string = '';
}
export class VpnSessionReport extends VpnState {
  requestId: string = '';
  stage: string = 'starting';
  created: boolean = false;
  processProtected: boolean = false;
  coreClosed: boolean = false;
  descriptorClosed: boolean = false;
  destroyed: boolean = false;
}
export function tailnetIPv4(value: string): boolean {
  const parts = value.split('.');
  return parts.length === 4 && parts.every((part: string) => /^(0|[1-9][0-9]{0,2})$/.test(part) && Number(part) <= 255) &&
    Number(parts[0]) === 100 && Number(parts[1]) >= 64 && Number(parts[1]) <= 127;
}
export function readVpnState(raw: string): VpnState {
  const s = JSON.parse(raw) as VpnState;
  if (!s || typeof s.ok !== 'boolean' || typeof s.connected !== 'boolean' ||
    typeof s.state !== 'string' || typeof s.error !== 'string' || typeof s.ipv4 !== 'string' ||
    ![s.txPackets, s.rxPackets, s.txBytes, s.rxBytes].every((n: number) => Number.isFinite(n) && n >= 0) ||
    (s.debugLogs !== undefined && (!Array.isArray(s.debugLogs) || !s.debugLogs.every((line: string) => typeof line === 'string'))) ||
    (s.coreId !== undefined && typeof s.coreId !== 'string') ||
    (s.coreHost !== undefined && s.coreHost !== '' && s.coreHost !== 'account' && s.coreHost !== 'vpn') ||
    (s.coreAlive !== undefined && typeof s.coreAlive !== 'boolean') ||
    (s.coreOwner !== undefined && typeof s.coreOwner !== 'boolean') ||
    (s.attached !== undefined && typeof s.attached !== 'boolean') ||
    (s.networkMapReady !== undefined && typeof s.networkMapReady !== 'boolean') ||
    (s.assignedIPv4 !== undefined && typeof s.assignedIPv4 !== 'string') ||
    (s.networkMapReady === true && (!s.coreAlive || !tailnetIPv4(s.assignedIPv4 || ''))) ||
    (s.startedAt !== undefined && (!Number.isFinite(s.startedAt) || s.startedAt < 0)) ||
    (s.connected && (!s.ok || s.state !== 'connected' || !tailnetIPv4(s.ipv4) || s.error !== ''))) {
    throw new Error('Invalid VPN service status');
  }
  return s;
}
export interface VpnSessionPort {
  create(ipv4: string): Promise<number>;
  protect(): Promise<void>;
  attach(fd: number, ipv4: string): Promise<string>;
  status(): Promise<string>;
  closeCore(): Promise<string>;
  closeDescriptor(fd: number): void;
  destroy(): Promise<void>;
  stopping(): boolean;
  delay(): Promise<void>;
}
interface CoreOperation { ok: boolean; error?: string; }
export class VpnSessionController {
  private cancelled: boolean = false;
  private active: boolean = false;
  cancel(): void { this.cancelled = true; }
  private check(): void { if (this.cancelled) { throw new Error('VPN startup cancelled'); } }
  async run(port: VpnSessionPort, id: string, ipv4: string,
    publish: (report: VpnSessionReport) => void): Promise<VpnSessionReport> {
    if (this.active) { throw new Error('VPN session already active'); }
    this.active = true;
    const r = new VpnSessionReport(); r.requestId = id; r.ipv4 = ipv4; r.state = 'connecting';
    let fd = -1;
    let coreTouched = false;
    try {
      this.check();
      if (!tailnetIPv4(ipv4)) { throw new Error('An assigned Tailnet IPv4 is required'); }
      r.stage = 'create'; publish(r);
      fd = await port.create(ipv4); r.created = true;
      if (!Number.isInteger(fd) || fd < 0) { throw new Error('Invalid VPN descriptor'); }
      this.check(); r.stage = 'protectProcessNet'; publish(r);
      await port.protect(); r.processProtected = true;
      this.check(); r.stage = 'attachCore'; publish(r); coreTouched = true;
      const attached = JSON.parse(await port.attach(fd, ipv4)) as CoreOperation;
      if (!attached || attached.ok !== true) { throw new Error(attached?.error || 'VPN core startup failed'); }
      // Go has its own duplicate after attach. Close the ArkTS original once.
      const original = fd; fd = -1;
      port.closeDescriptor(original); r.descriptorClosed = true;
      this.check();
      let deadline = Date.now() + 45000;
      let wasConnected = false;
      while (!this.cancelled && !port.stopping()) {
        const s = readVpnState(await port.status());
        this.check();
        if (!s.ok) { throw new Error(s.error || 'VPN packet path failed'); }
        if (s.ipv4 !== ipv4) { throw new Error('Tailnet address changed; reconnect VPN'); }
        r.connected = s.connected; r.state = s.state; r.txPackets = s.txPackets; r.rxPackets = s.rxPackets;
        r.txBytes = s.txBytes; r.rxBytes = s.rxBytes; r.stage = s.connected ? 'connected' : 'connecting';
        r.debugLogs = s.debugLogs || [];
        if (s.connected) { deadline = Date.now() + 90000; wasConnected = true; }
        else if (Date.now() >= deadline) { throw new Error(wasConnected ? 'VPN reconnection timed out' : 'VPN control connection timed out'); }
        publish(r); await port.delay();
      }
    } catch (error) { r.ok = false; r.error = `${r.stage}: ${error}`; }
    finally {
      r.connected = false; r.state = 'disconnecting'; r.stage = 'cleanup';
      try { publish(r); } catch (error) { r.error += `; publish: ${error}`; }
      if (coreTouched) {
        try {
          const closed = JSON.parse(await port.closeCore()) as CoreOperation;
          if (!closed || closed.ok !== true) { throw new Error(closed?.error || 'core cleanup failed'); }
          r.coreClosed = true;
        } catch (error) { r.error += `; closeCore: ${error}`; }
      } else { r.coreClosed = true; }
      if (fd >= 0) {
        try { port.closeDescriptor(fd); r.descriptorClosed = true; }
        catch (error) { r.error += `; closeDescriptor: ${error}`; }
      }
      if (r.created) {
        try { await port.destroy(); r.destroyed = true; }
        catch (error) { r.error += `; destroy: ${error}`; }
      } else { r.destroyed = true; }
      r.ok = !r.error; r.stage = r.ok ? 'stopped' : 'failed'; r.state = r.ok ? 'disconnected' : 'error';
      this.active = false;
      try { publish(r); } catch (_error) { /* resources have already been released */ }
    }
    return r;
  }
}
