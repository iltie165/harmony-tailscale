import { VpnState, readVpnState, tailnetIPv4 } from './VpnSessionModel';
import { ControlResult, readControl, isAuthenticated } from '../pages/ClientModel';

export class ServiceCommand {
  version: number = 1;
  ownerId: string = '';
  commandId: string = '';
  enabled: boolean = false;
  shutdown: boolean = false;
}
export class ServiceSnapshot extends VpnState {
  version: number = 1;
  ownerId: string = '';
  commandId: string = '';
  phase: string = 'booting';
  desiredEnabled: boolean = false;
  serviceReady: boolean = false;
  created: boolean = false;
  processProtected: boolean = false;
  detached: boolean = true;
  descriptorClosed: boolean = true;
  destroyed: boolean = true;
  timestamp: number = 0;
  bootDurationMs: number = 0;
  stopReason: string = '';
}
export function readServiceSnapshot(raw: string): ServiceSnapshot {
  const s = JSON.parse(raw) as ServiceSnapshot;
  readVpnState(raw);
  if (s.version !== 1 || typeof s.ownerId !== 'string' || !/^[0-9-]{1,80}$/.test(s.ownerId) ||
    typeof s.commandId !== 'string' || typeof s.phase !== 'string' ||
    typeof s.desiredEnabled !== 'boolean' || typeof s.serviceReady !== 'boolean' ||
    typeof s.created !== 'boolean' || typeof s.processProtected !== 'boolean' ||
    typeof s.detached !== 'boolean' || typeof s.destroyed !== 'boolean' ||
    typeof s.descriptorClosed !== 'boolean' ||
    typeof s.coreId !== 'string' || typeof s.coreAlive !== 'boolean' ||
    !Number.isFinite(s.timestamp) || typeof s.stopReason !== 'string' ||
    (s.serviceReady && (!s.coreAlive || !s.coreId)) ||
    (s.connected && (!s.serviceReady || s.detached || s.destroyed || !s.created || !s.processProtected || !s.descriptorClosed))) {
    throw new Error('Invalid network service snapshot');
  }
  return s;
}
export function readServiceCommand(raw: string): ServiceCommand {
  const c = JSON.parse(raw) as ServiceCommand;
  if (!c || c.version !== 1 || typeof c.ownerId !== 'string' || typeof c.commandId !== 'string' || !/^[0-9-]{1,80}$/.test(c.ownerId) ||
    !/^[0-9-]{1,80}$/.test(c.commandId) || typeof c.enabled !== 'boolean' || typeof c.shutdown !== 'boolean') {
    throw new Error('Invalid network service command');
  }
  return c;
}
export interface NetworkServicePort {
  orphanedNetwork(): boolean;
  boot(): Promise<string>;
  control(): Promise<string>;
  status(): Promise<string>;
  create(ipv4: string): Promise<number>;
  protect(): Promise<void>;
  attach(fd: number, ipv4: string): Promise<string>;
  detach(): Promise<string>;
  closeDescriptor(fd: number): void;
  destroy(): Promise<void>;
  closeCore(): Promise<string>;
  request(): ServiceCommand | undefined;
  publish(snapshot: ServiceSnapshot): void;
  delay(): Promise<void>;
}

// Extension-owned actor. It outlives page observers, serializes SDK/native
// mutations, and retains the same core through normal OFF/ON. No 90s teardown
// is triggered merely because the control plane is reconnecting.
export class NetworkServiceActor {
  private cancelled: boolean = false;
  private reason: string = 'system_destroyed';
  private active: boolean = false;
  private pendingDescriptor: number = -1;
  private nativeTouched: boolean = false;
  private blockedCommand: string = '';
  cancel(reason: string = 'system_destroyed'): void { if (!this.cancelled) { this.cancelled = true; this.reason = reason; } }
  private publish(port: NetworkServicePort, s: ServiceSnapshot): void {
    s.timestamp = Date.now(); port.publish(s);
  }
  private accept(port: NetworkServicePort, s: ServiceSnapshot): void {
    const c = port.request();
    if (!c || c.ownerId !== s.ownerId) { return; }
    if (c.shutdown) { this.cancel('user_shutdown'); }
    if (c.commandId !== s.commandId) {
      s.commandId = c.commandId; s.desiredEnabled = c.enabled && !c.shutdown;
      if (s.detached && s.destroyed && s.descriptorClosed) { s.error = ''; s.ok = true; }
    }
  }
  private check(port: NetworkServicePort, s: ServiceSnapshot): void {
    this.accept(port,s);
    if (this.cancelled || !s.desiredEnabled) { throw new Error('VPN request cancelled'); }
  }
  private async cleanup(port: NetworkServicePort, s: ServiceSnapshot): Promise<void> {
    s.connected = false; s.phase = 'disconnecting'; s.state = 'disconnecting';
    let error = '';
    try { this.publish(port,s); } catch (e) { error += `publish: ${e}; `; }
    if (this.nativeTouched) {
      try { readControl(await port.detach()); s.detached = true; this.nativeTouched = false; }
      catch (e) { error += `detach: ${e}; `; }
    }
    if (this.pendingDescriptor >= 0) {
      const fd = this.pendingDescriptor; this.pendingDescriptor = -1;
      try { port.closeDescriptor(fd); s.descriptorClosed = true; } catch (e) { error += `descriptor: ${e}; `; }
    }
    if (!s.destroyed) {
      try { await port.destroy(); s.destroyed = true; s.created = false; s.processProtected = false; }
      catch (e) { error += `destroy: ${e}; `; }
    }
    if (!s.descriptorClosed && !error) { error = 'Original descriptor close unconfirmed; stop network service'; }
    s.attached = !s.detached; s.ipv4 = s.detached ? '' : s.ipv4;
    s.phase = error ? 'cleanup_pending' : 'idle'; s.state = error ? 'error' : 'disconnected';
    s.ok = !error; s.error = error;
    this.publish(port,s);
    if (error) { throw new Error(error); }
  }
  private async enable(port: NetworkServicePort, s: ServiceSnapshot, control: ControlResult): Promise<void> {
    if (!isAuthenticated(control)) { throw new Error('账号需要重新认证，请先登录'); }
    const ipv4 = control.tailscaleIPs?.find((ip: string) => tailnetIPv4(ip));
    if (control.backendState !== 'Running' || !ipv4) {
      s.phase = 'waiting_core'; s.state = 'connecting'; this.publish(port,s); return;
    }
    this.check(port,s);
    s.phase = 'create'; s.ipv4 = ipv4; this.publish(port,s);
    this.pendingDescriptor = await port.create(ipv4); s.created = true; s.destroyed = false; s.descriptorClosed = false;
    if (!Number.isInteger(this.pendingDescriptor) || this.pendingDescriptor < 0) { throw new Error('Invalid VPN descriptor'); }
    this.check(port,s); s.phase = 'protect'; this.publish(port,s);
    await port.protect(); s.processProtected = true;
    this.check(port,s); s.phase = 'attach'; this.publish(port,s);
    this.nativeTouched = true; s.detached = false;
    readControl(await port.attach(this.pendingDescriptor,ipv4));
    const original = this.pendingDescriptor; this.pendingDescriptor = -1;
    port.closeDescriptor(original);
    s.descriptorClosed = true;
    this.check(port,s);
  }
  async run(port: NetworkServicePort, ownerId: string): Promise<ServiceSnapshot> {
    if (this.active) { throw new Error('Network service actor already running'); }
    this.active = true;
    const s = new ServiceSnapshot(); s.ownerId = ownerId;
    let coreTouched = false;
    let ownsCore = false;
    try {
      if (port.orphanedNetwork()) { s.created = true; s.destroyed = false; }
      this.publish(port,s);
      coreTouched = true;
      readControl(await port.boot());
      const initial = readVpnState(await port.status());
      if (!initial.coreAlive || !initial.coreId || !initial.coreOwner) { throw new Error('Exclusive core ownership could not be confirmed'); }
      ownsCore = true;
      s.coreId = initial.coreId; s.coreAlive = true; s.coreOwner = true; s.startedAt = initial.startedAt;
      // Only after acquiring the exclusive native lease may a new generation
      // clean a network left behind by its previous own-app owner.
      if (!s.destroyed) { await this.cleanup(port,s); }
      s.bootDurationMs = Math.max(0,Date.now()-initial.startedAt);
      s.serviceReady = true; s.phase = 'idle'; this.publish(port,s);
      while (!this.cancelled) {
        this.accept(port,s);
        if (this.cancelled) { break; }
        try {
          if (!s.desiredEnabled && (!s.detached || !s.destroyed || this.pendingDescriptor >= 0)) {
            s.stopReason = 'user_off'; await this.cleanup(port,s);
          }
          if (s.desiredEnabled && s.commandId !== this.blockedCommand && s.detached && s.destroyed && s.descriptorClosed) {
            const control = readControl(await port.control());
            this.accept(port,s);
            if (s.desiredEnabled && !this.cancelled) { await this.enable(port,s,control); }
          }
          const current = readVpnState(await port.status());
          if (!current.coreAlive || current.coreId !== s.coreId) { this.cancel('core_failed'); throw new Error('Core process/generation changed'); }
          if (!current.ok) { throw new Error(current.error || 'Packet path failed'); }
          if (s.desiredEnabled && !s.detached) {
            s.connected = current.connected; s.attached = current.attached;
            s.phase = current.connected ? 'connected' : 'reconnecting'; s.state = current.state;
            s.txPackets = current.txPackets; s.rxPackets = current.rxPackets;
            s.txBytes = current.txBytes; s.rxBytes = current.rxBytes; s.debugLogs = current.debugLogs || [];
            if (current.ipv4 !== s.ipv4) { throw new Error('Interface address changed; reconnect VPN'); }
          }
          this.publish(port,s);
        } catch (e) {
          const command = s.commandId;
          const message = `${e}`;
          try { await this.cleanup(port,s); }
          catch (_cleanupError) { /* cleanup_pending remains authoritative */ }
          this.accept(port,s);
          if (s.commandId === command && s.desiredEnabled) { this.blockedCommand = command; }
          if (s.detached && s.destroyed && s.descriptorClosed) {
            if (!s.desiredEnabled) { s.phase='idle';s.state='disconnected';s.ok=true;s.error='';s.stopReason='user_off'; }
            else { s.phase = 'error';s.state = 'error';s.ok = false;s.error = message;s.stopReason='operation_error'; }
          } else { s.stopReason='operation_error'; }
          this.publish(port,s);
        }
        await port.delay();
      }
    } catch (e) { s.ok = false; s.error = `Service startup: ${e}`; }
    finally {
      const priorError = s.error;
      s.desiredEnabled = false; s.stopReason = this.reason;
      if (ownsCore) { try { await this.cleanup(port,s); } catch (_e) {} }
      try { if (coreTouched) { readControl(await port.closeCore()); } s.coreAlive = false; s.coreOwner = false; }
      catch (e) { s.error += `; core shutdown: ${e}`; s.ok = false; }
      s.serviceReady = false;
      s.phase = !s.coreAlive && s.detached && s.destroyed && s.descriptorClosed ? 'stopped' : 'cleanup_pending';
      if (s.phase === 'stopped') { s.state = 'disconnected'; }
      if (priorError && !s.error) { s.error = priorError; }
      s.ok = !s.error && s.phase === 'stopped';
      this.active = false;
      try { this.publish(port,s); } catch (_e) {}
    }
    return s;
  }
}
