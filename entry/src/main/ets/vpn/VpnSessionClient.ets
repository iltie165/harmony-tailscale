import { VpnSessionReport, readVpnState } from './VpnSessionModel';

export interface VpnSessionRequest {
  start(): Promise<void>;
  stop(): Promise<void>;
  read(): string;
  requestStop(id: string): void;
  delay(): Promise<void>;
}
export class VpnSessionError extends Error {
  cleanupConfirmed: boolean;
  constructor(message: string, cleanupConfirmed: boolean) { super(message); this.cleanupConfirmed = cleanupConfirmed; }
}
let activeRequest: boolean = false;
let sdkCalls: number = 0;
let lateCleanup: number = 0;
export function vpnSdkPending(): boolean { return activeRequest || sdkCalls > 0 || lateCleanup > 0; }
function trackSdk(call: () => Promise<void>): Promise<void> {
  sdkCalls++;
  try { return call().then(() => { sdkCalls--; }, (error: Error) => { sdkCalls--; throw error; }); }
  catch (error) { sdkCalls--; return Promise.reject(new Error(`${error}`)); }
}
export function boundedVpn<T>(work: Promise<T>, milliseconds: number, name: string): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => { reject(new Error(`${name} timed out; cleanup remains unverified`)); }, milliseconds);
    work.then((value: T) => { clearTimeout(timer); resolve(value); },
      (error: Error) => { clearTimeout(timer); reject(error); });
  });
}
function matchingReport(port: VpnSessionRequest, id: string): VpnSessionReport | undefined {
  const raw = port.read();
  if (!raw) { return undefined; }
  const r = JSON.parse(raw) as VpnSessionReport;
  if (!r || r.requestId !== id) { return undefined; }
  readVpnState(raw);
  if (typeof r.stage !== 'string' || typeof r.destroyed !== 'boolean' || typeof r.coreClosed !== 'boolean') {
    throw new Error('Invalid VPN session report');
  }
  return r;
}
export async function stopVpnSession(port: VpnSessionRequest, id: string): Promise<void> {
  port.requestStop(id);
  try {
    const wait = async (): Promise<void> => {
      const deadline = Date.now() + 30000;
      while (Date.now() < deadline) {
        const r = matchingReport(port, id);
        if (r && (r.stage === 'stopped' || r.stage === 'failed')) {
          if (!r.coreClosed || !r.destroyed) { throw new Error(r.error || 'VPN cleanup incomplete'); }
          return;
        }
        await port.delay();
      }
      throw new Error('VPN cleanup timed out');
    };
    await boundedVpn(wait(), 31000, 'VPN cleanup');
  } finally { await boundedVpn(trackSdk(() => port.stop()), 10000, 'stopVpnExtensionAbility'); }
}
export async function startVpnSession(port: VpnSessionRequest, id: string,
  cancelled: () => boolean, progress: (stage: string) => void): Promise<VpnSessionReport> {
  if (vpnSdkPending()) { throw new Error('Previous VPN SDK operation is still pending'); }
  activeRequest = true;
  let abandoned = false;
  let settled = false;
  let started = false;
  const work = trackSdk(() => port.start()).then(async () => {
    started = true; settled = true;
    if (abandoned) {
      lateCleanup++;
      try { await stopVpnSession(port, id); } finally { lateCleanup--; }
    }
  }, (error: Error) => { settled = true; throw error; });
  try {
    progress('authorization');
    await boundedVpn(work, 60000, 'startVpnExtensionAbility');
    const deadline = Date.now() + 55000;
    while (Date.now() < deadline) {
      if (cancelled()) { throw new Error('VPN request cancelled'); }
      const r = matchingReport(port, id);
      if (r) {
        progress(r.stage);
        if (r.stage === 'failed' || r.stage === 'stopped') { throw new Error(r.error || 'VPN stopped before connection'); }
        if (r.connected && r.stage === 'connected' && r.created && r.processProtected) { return r; }
      }
      await port.delay();
    }
    throw new Error('VPN startup timed out');
  } catch (error) {
    abandoned = true;
    let cleanupConfirmed = settled && !started;
    let message = `${error}`;
    if (started) {
      try { await stopVpnSession(port, id); cleanupConfirmed = true; }
      catch (cleanupError) { message += `; cleanup: ${cleanupError}`; }
    }
    throw new VpnSessionError(message, cleanupConfirmed);
  } finally { activeRequest = false; }
}
