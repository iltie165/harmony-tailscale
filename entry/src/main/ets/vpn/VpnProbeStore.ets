import { fileIo } from '@kit.CoreFileKit';
import { VpnProbeReport } from './VpnProbeModel';

export function vpnProbePath(filesDir: string): string {
  return `${filesDir}/vpn-capability-probe.json`;
}

export function writeVpnProbe(filesDir: string, report: VpnProbeReport): void {
  const path = vpnProbePath(filesDir);
  const temporary = `${path}.tmp`;
  const file = fileIo.openSync(temporary,
    fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
  try { fileIo.writeSync(file.fd, JSON.stringify(report)); }
  finally { fileIo.closeSync(file); }
  fileIo.renameSync(temporary, path);
}
