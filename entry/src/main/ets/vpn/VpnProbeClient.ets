import { VpnProbeReport, readVpnProbe } from './VpnProbeModel';

export interface VpnProbeRequestPort {
  start(): Promise<void>;
  stop(): Promise<void>;
  read(): string;
  delay(): Promise<void>;
}

// File snapshots cross the extension/UI process boundary. A stale result must
// never complete a newer request; no process-local emitter/singleton is assumed.
export async function requestVpnProbe(port: VpnProbeRequestPort, requestId: string,
  cancelled: () => boolean): Promise<VpnProbeReport> {
  let started = false;
  let report: VpnProbeReport | undefined = undefined;
  let failure = '';
  try {
    if (cancelled()) { throw new Error('VPN probe request cancelled'); }
    await port.start();
    started = true;
    for (let attempt = 0; attempt < 60; attempt++) {
      if (cancelled()) { throw new Error('VPN probe request cancelled'); }
      const raw = port.read();
      if (raw) {
        const candidate = JSON.parse(raw) as VpnProbeReport;
        if (candidate && candidate.requestId === requestId) {
          const current = readVpnProbe(raw, requestId);
          if (current.stage === 'complete' || current.stage === 'failed') { report = current; break; }
        }
      }
      await port.delay();
    }
    if (!report) { throw new Error('VPN probe timed out; authorization/runtime/cleanup remains unverified'); }
  } catch (error) { failure = `${error}`; }
  finally {
    if (started) {
      try { await port.stop(); }
      catch (error) { failure += `; stopVpnExtensionAbility: ${error}`; }
    }
  }
  if (failure) { throw new Error(failure); }
  if (!report) { throw new Error('VPN probe returned no report'); }
  return report;
}
