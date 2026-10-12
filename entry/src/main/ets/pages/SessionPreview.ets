import { fileIo } from '@kit.CoreFileKit';
import { ControlResult, PeerInfo, readControl, readPeers } from './ClientModel';

// Display cache only. Never use this snapshot as authentication or VPN readiness.
// Whitelist metadata: credentials, login URLs, logs and VPN state are not stored.
export class SessionPreview {
  version: number = 1;
  account: ControlResult = {};
  peers: PeerInfo[] = [];
  updatedAt: string = '';
  syncedAt: string = '';
}
function peerMetadata(peer: PeerInfo): PeerInfo {
  return { id: peer.id, online: peer.online, hostName: peer.hostName, dnsName: peer.dnsName,
    os: peer.os, userLogin: peer.userLogin, userName: peer.userName,
    tailscaleIPs: peer.tailscaleIPs, tags: peer.tags };
}
export function previewOf(account: ControlResult, peers: PeerInfo[], updatedAt: string, syncedAt: string = updatedAt): SessionPreview {
  const result = new SessionPreview();
  result.account = { self: account.self ? peerMetadata(account.self) : undefined,
    tailscaleIPs: account.tailscaleIPs,
    tailnet: account.tailnet ? { name: account.tailnet.name, magicDNSSuffix: account.tailnet.magicDNSSuffix } : undefined };
  result.peers = peers.map((peer: PeerInfo) => peerMetadata(peer));
  result.updatedAt = updatedAt;
  result.syncedAt = syncedAt;
  return result;
}
export function readPreview(raw: string): SessionPreview {
  if (raw.length > 524288) { throw new Error('Display cache too large'); }
  const result = JSON.parse(raw) as SessionPreview;
  if (!result || result.version !== 1 || !result.account || !result.account.self ||
    typeof result.updatedAt !== 'string' || (result.syncedAt !== undefined && typeof result.syncedAt !== 'string') || !Array.isArray(result.peers)) {
    throw new Error('Invalid display cache');
  }
  readControl(JSON.stringify({ ok: true, self: result.account.self,
    tailscaleIPs: result.account.tailscaleIPs, tailnet: result.account.tailnet }));
  const peers = readPeers(JSON.stringify({ ok: true, peers: result.peers }));
  return previewOf(result.account, peers, result.updatedAt, result.syncedAt === undefined ? result.updatedAt : result.syncedAt);
}
export class SessionPreviewStore {
  private path: string;
  constructor(dir: string) { this.path = `${dir}/tailscale-display.json`; }
  read(): SessionPreview | undefined {
    try { return fileIo.accessSync(this.path) ? readPreview(fileIo.readTextSync(this.path)) : undefined; }
    catch (_error) { return undefined; }
  }
  write(preview: SessionPreview): void {
    // A tombstone is atomic too, so logout cannot resurrect the last display cache.
    const raw = preview.account.self ? JSON.stringify(readPreview(JSON.stringify(preview))) : '{}';
    const file = fileIo.openSync(`${this.path}.tmp`, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    try { fileIo.writeSync(file.fd, raw); } finally { fileIo.closeSync(file); }
    fileIo.renameSync(`${this.path}.tmp`, this.path);
  }
}
