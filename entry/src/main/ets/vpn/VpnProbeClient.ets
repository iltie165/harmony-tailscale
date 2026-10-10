import { VpnProbeReport, readVpnProbe } from './VpnProbeModel';

export interface VpnProbeRequestPort {
  start(): Promise<void>;
  stop(): Promise<void>;
  read(): string;
  delay(): Promise<void>;
}

// A timed-out SDK Promise is not cancelled. Hold the lease until it settles,
// including late cleanup, so its stop cannot tear down a newer request.
let requestActive: boolean = false;

function boundedOperation<T>(operation: Promise<T>, milliseconds: number,
  stage: () => string, cancelled: () => boolean): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    let done = false;
    let cancellationTimer = -1;
    const timeoutTimer = setTimeout(() => {
      finish();
      reject(new Error(`VPN probe timed out at ${stage()}; authorization/runtime/cleanup remains unverified`));
    }, milliseconds);
    const finish = (): void => {
      done = true;
      clearTimeout(timeoutTimer);
      if (cancellationTimer !== -1) { clearTimeout(cancellationTimer); }
    };
    const checkCancellation = (): void => {
      if (done) { return; }
      if (cancelled()) {
        finish();
        reject(new Error(`VPN probe request cancelled at ${stage()}`));
      } else { cancellationTimer = setTimeout(checkCancellation, 250); }
    };
    checkCancellation();
    operation.then((value: T) => {
      if (!done) { finish(); resolve(value); }
    }, (error: Error) => {
      if (!done) { finish(); reject(error); }
    });
  });
}

// File snapshots cross the extension/UI process boundary. A stale result must
// never complete a newer request; no process-local emitter/singleton is assumed.
export async function requestVpnProbe(port: VpnProbeRequestPort, requestId: string,
  cancelled: () => boolean, progress: (stage: string, raw: string) => void = () => {}): Promise<VpnProbeReport> {
  if (cancelled()) { throw new Error('VPN probe request cancelled'); }
  if (requestActive) { throw new Error('Previous VPN SDK operation is still pending; cleanup remains unverified. Restart the app before retrying.'); }
  requestActive = true;
  let started = false;
  let startSettled = false;
  let stopSettled = true;
  let finished = false;
  let stopWork: Promise<void> | undefined = undefined;
  let report: VpnProbeReport | undefined = undefined;
  let failure = '';
  let stage = 'startVpnExtensionAbility';
  const releaseIfSettled = (): void => {
    if (finished && startSettled && stopSettled) { requestActive = false; }
  };
  const stopOnce = (): Promise<void> => {
    if (!stopWork) {
      stopSettled = false;
      stopWork = Promise.resolve().then(() => port.stop());
      stopWork.then(() => { stopSettled = true; releaseIfSettled(); },
        () => { stopSettled = true; releaseIfSettled(); });
    }
    return stopWork;
  };
  const startWork = (async (): Promise<void> => { await port.start(); })().then(() => {
    startSettled = true;
    started = true;
    if (finished) { stopOnce().catch(() => {}); }
    releaseIfSettled();
  }, (error: Error) => { startSettled = true; releaseIfSettled(); throw error; });
  try {
    progress(stage, '');
    await boundedOperation(startWork, 60000, () => stage, cancelled);
    stage = 'awaitExtensionReport';
    progress(stage, '');
    const poll = async (): Promise<VpnProbeReport> => {
      for (let attempt = 0; attempt < 30; attempt++) {
        if (finished || cancelled()) { throw new Error('VPN probe request cancelled'); }
        const raw = port.read();
        if (raw) {
          const candidate = JSON.parse(raw) as VpnProbeReport;
          if (candidate && candidate.requestId === requestId) {
            const current = readVpnProbe(raw, requestId);
            stage = current.stage;
            progress(stage, raw);
            if (current.stage === 'complete' || current.stage === 'failed') { return current; }
          }
        }
        await port.delay();
      }
      throw new Error(`VPN probe timed out at ${stage}; authorization/runtime/cleanup remains unverified`);
    };
    report = await boundedOperation(poll(), 30000, () => stage, cancelled);
  } catch (error) { failure = `${error}`; }
  finally {
    finished = true;
    if (started) {
      stage = 'stopVpnExtensionAbility';
      if (!cancelled()) { progress(stage, ''); }
      try { await boundedOperation(stopOnce(), 10000, () => stage, () => false); }
      catch (error) { failure += `; stopVpnExtensionAbility: ${error}`; }
    }
    releaseIfSettled();
  }
  if (failure) { throw new Error(failure); }
  if (!report) { throw new Error('VPN probe returned no report'); }
  return report;
}
