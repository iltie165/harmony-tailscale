// User intent is independent of extension generations and display metadata.
export class VpnIntent {
  version: number = 1;
  enabled: boolean = false;
  revision: string = '';
}
export function readVpnIntent(raw: string): VpnIntent {
  const value = JSON.parse(raw) as VpnIntent;
  if (!value || value.version !== 1 || typeof value.enabled !== 'boolean' ||
    typeof value.revision !== 'string' || !/^[0-9-]{1,80}$/.test(value.revision)) {
    throw new Error('Invalid VPN intent');
  }
  return value;
}
export class RecoveryReport {
  phase: string = 'off';
  attempts: number = 0;
  nextRetryAt: number = 0;
  interruptedAt: number = 0;
  recoveredAt: number = 0;
  lastRecoveryMs: number = 0;
  error: string = '';
}
export class RecoveryBlocked extends Error {
  constructor(message: string) { super(message); }
}
export interface VpnRecoveryPort {
  readIntent(): VpnIntent | undefined;
  writeIntent(value: VpnIntent): void;
  recover(intent: VpnIntent, current: () => boolean, progress: (message: string) => void): Promise<void>;
  cancel(): void;
  disconnect(): Promise<void>;
  publish(report: RecoveryReport): void;
}

// App-runtime supervisor, deliberately independent of page/foreground timers.
// A timer is not a wake lock: suspended/killed runtimes cannot execute it.
export class VpnRecoverySupervisor {
  private port: VpnRecoveryPort;
  private intent: VpnIntent = new VpnIntent();
  private timer: number = -1;
  private task: Promise<void> | undefined = undefined;
  private running: boolean = false;
  private suspended: boolean = false;
  private report: RecoveryReport = new RecoveryReport();
  constructor(port: VpnRecoveryPort) { this.port = port; }
  wanted(): boolean { return this.intent.enabled; }
  diagnostics(): RecoveryReport { return this.report; }
  start(): void {
    if (this.running) { return; }
    try { this.intent = this.port.readIntent() || new VpnIntent(); }
    catch (e) { this.report.phase = 'blocked'; this.report.error = `开启意图无法读取：${e}`; this.suspended = true; }
    this.running = true; this.schedule(0);
  }
  stop(): void {
    this.running = false;
    if (this.timer !== -1) { clearTimeout(this.timer); this.timer = -1; }
  }
  private schedule(delay: number): void {
    if (this.timer !== -1) { clearTimeout(this.timer); this.timer = -1; }
    if (!this.running || !this.intent.enabled || this.suspended) { return; }
    this.timer = setTimeout(() => {
      this.timer = -1;
      this.check().catch(() => {}).finally(() => {
        this.schedule(Math.max(1000, this.report.nextRetryAt - Date.now()));
      });
    }, delay);
  }
  private publish(): void { this.port.publish(this.report); }
  async setWanted(enabled: boolean, progress: (message: string) => void): Promise<void> {
    const next = new VpnIntent(); next.enabled = enabled;
    next.revision = `${Date.now()}-${Math.floor(Math.random() * 1000000000)}`;
    // A storage failure must not silently accept an intent which cannot survive
    // a restart. OFF still cancels in-memory and pending SDK work before failing.
    let stopError = '';
    if (!enabled) {
      this.intent = next; this.stop();
      try { this.port.cancel(); } catch (e) { stopError = `取消开启失败：${e}`; }
    }
    try { this.port.writeIntent(next); }
    catch (e) {
      if (enabled) { throw e as Error; }
      stopError += `; 关闭意图保存失败：${e}`;
    }
    this.intent = next; this.suspended = false;
    this.report = new RecoveryReport(); this.report.phase = enabled ? 'recovering' : 'off'; this.publish();
    if (!enabled) {
      if (this.task) { await this.task.catch(() => {}); }
      await this.port.disconnect();
      if (stopError) { throw new Error(stopError); }
      return;
    }
    this.running = true;
    try {
      if (this.task) { await this.task.catch(() => {}); }
      if (this.intent.revision === next.revision) { await this.check(progress); }
    }
    finally { this.schedule(Math.max(1000, this.report.nextRetryAt - Date.now())); }
  }
  async check(progress: (message: string) => void = (_message: string): void => {}): Promise<void> {
    if (this.task) { return this.task; }
    if (!this.intent.enabled || this.suspended || Date.now() < this.report.nextRetryAt) { return; }
    const intent = this.intent;
    const current = (): boolean => this.intent.enabled && this.intent.revision === intent.revision;
    this.task = this.attempt(intent, current, progress);
    try { await this.task; } finally { this.task = undefined; }
  }
  private async attempt(intent: VpnIntent, current: () => boolean, progress: (message: string) => void): Promise<void> {
    try {
      await this.port.recover(intent, current, progress);
      if (!current()) { return; }
      if (this.report.interruptedAt) {
        this.report.recoveredAt = Date.now(); this.report.lastRecoveryMs = Math.max(0, Date.now() - this.report.interruptedAt);
      }
      this.report.phase = 'connected'; this.report.attempts = 0;
      this.report.nextRetryAt = 0; this.report.interruptedAt = 0; this.report.error = ''; this.publish();
    } catch (e) {
      if (!current()) { return; }
      if (!this.report.interruptedAt) { this.report.interruptedAt = Date.now(); }
      this.report.attempts++; this.report.error = `${e}`;
      this.suspended = e instanceof RecoveryBlocked;
      this.report.phase = this.suspended ? 'blocked' : 'retry_wait';
      this.report.nextRetryAt = this.suspended ? 0 : Date.now() + Math.min(30000, 1000 * Math.pow(2, Math.min(5, this.report.attempts - 1)));
      this.publish(); throw e as Error;
    }
  }
}
