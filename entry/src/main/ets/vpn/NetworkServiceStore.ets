import { fileIo } from '@kit.CoreFileKit';
import { ServiceCommand, ServiceSnapshot, readServiceCommand, readServiceSnapshot } from './NetworkServiceModel';
import { VpnIntent, readVpnIntent } from './VpnRecoveryModel';

function atomic(path: string, value: string): void {
  const file = fileIo.openSync(`${path}.tmp`,fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
  try { fileIo.writeSync(file.fd,value); } finally { fileIo.closeSync(file); }
  fileIo.renameSync(`${path}.tmp`,path);
}
export class NetworkServiceStore {
  private snapshotPath: string;
  private commandPath: string;
  private intentPath: string;
  constructor(dir: string) {
    this.snapshotPath = `${dir}/network-service.json`;
    this.commandPath = `${dir}/network-service-command.json`;
    this.intentPath = `${dir}/vpn-intent.json`;
  }
  read(): ServiceSnapshot | undefined {
    if (!fileIo.accessSync(this.snapshotPath)) { return undefined; }
    return readServiceSnapshot(fileIo.readTextSync(this.snapshotPath));
  }
  request(): ServiceCommand | undefined {
    // An incomplete/corrupt old command must not kill a healthy service.
    try { return fileIo.accessSync(this.commandPath) ? readServiceCommand(fileIo.readTextSync(this.commandPath)) : undefined; }
    catch (_error) { return undefined; }
  }
  publish(snapshot: ServiceSnapshot): void { atomic(this.snapshotPath,JSON.stringify(snapshot)); }
  command(value: ServiceCommand): void { atomic(this.commandPath,JSON.stringify(value)); }
  intent(): VpnIntent | undefined {
    return fileIo.accessSync(this.intentPath) ? readVpnIntent(fileIo.readTextSync(this.intentPath)) : undefined;
  }
  saveIntent(value: VpnIntent): void { atomic(this.intentPath,JSON.stringify(value)); }
}
