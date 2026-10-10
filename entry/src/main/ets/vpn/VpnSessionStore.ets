import { fileIo } from '@kit.CoreFileKit';
import { VpnSessionReport } from './VpnSessionModel';

export function sessionPath(dir: string): string { return `${dir}/vpn-session.json`; }
export function stopPath(dir: string): string { return `${dir}/vpn-session-stop.json`; }
function writeAtomic(path: string, text: string): void {
  const file = fileIo.openSync(`${path}.tmp`, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
  try { fileIo.writeSync(file.fd, text); } finally { fileIo.closeSync(file); }
  fileIo.renameSync(`${path}.tmp`, path);
}
export function publishSession(dir: string, report: VpnSessionReport): void {
  writeAtomic(sessionPath(dir), JSON.stringify(report));
}
export function requestSessionStop(dir: string, requestId: string): void {
  writeAtomic(stopPath(dir), requestId);
}
export function stopRequested(dir: string, requestId: string): boolean {
  const path = stopPath(dir);
  return fileIo.accessSync(path) && fileIo.readTextSync(path) === requestId;
}
export function readSession(dir: string): string {
  const path = sessionPath(dir);
  return fileIo.accessSync(path) ? fileIo.readTextSync(path) : '';
}
