// UI/native contract, independent of ArkUI so it can be tested on the server.
export interface PeerInfo {
  id: string;
  hostName?: string;
  dnsName?: string;
  os?: string;
  userLogin?: string;
  userName?: string;
  online: boolean;
  tailscaleIPs?: string[];
  tags?: string[];
  relay?: string;
}
export interface TailnetInfo { name?: string; magicDNSSuffix?: string; }
export interface ControlResult {
  ok?: boolean;
  backendState?: string;
  lifecycleState?: string;
  loggedIn?: boolean;
  authUrl?: string;
  self?: PeerInfo;
  tailnet?: TailnetInfo;
  tailscaleIPs?: string[];
  health?: string[];
  error?: string;
}
export interface PeersResult { ok: boolean; peers: PeerInfo[]; error?: string; }
export function readControl(raw: string): ControlResult {
  const result: ControlResult = JSON.parse(raw) as ControlResult;
  if (!result || result.ok !== true) {
    throw new Error(result?.error || '无法读取 Tailscale 状态');
  }
  if ((result.backendState !== undefined && typeof result.backendState !== 'string') ||
    (result.loggedIn !== undefined && typeof result.loggedIn !== 'boolean') ||
    (result.authUrl !== undefined && typeof result.authUrl !== 'string') ||
    (result.tailscaleIPs !== undefined && !validStringArray(result.tailscaleIPs)) ||
    (result.self !== undefined && !validPeer(result.self)) ||
    (result.tailnet !== undefined && (!result.tailnet || typeof result.tailnet !== 'object' ||
      (result.tailnet.name !== undefined && typeof result.tailnet.name !== 'string') ||
      (result.tailnet.magicDNSSuffix !== undefined && typeof result.tailnet.magicDNSSuffix !== 'string')))) {
    throw new Error('Tailscale 状态数据格式不正确');
  }
  return result;
}
function validStringArray(values: string[]): boolean {
  return Array.isArray(values) && values.every((value: string) => typeof value === 'string');
}
function validPeer(peer: PeerInfo): boolean {
  return !!peer && typeof peer === 'object' && typeof peer.id === 'string' &&
    typeof peer.online === 'boolean' &&
    (peer.hostName === undefined || typeof peer.hostName === 'string') &&
    (peer.dnsName === undefined || typeof peer.dnsName === 'string') &&
    (peer.os === undefined || typeof peer.os === 'string') &&
    (peer.userLogin === undefined || typeof peer.userLogin === 'string') &&
    (peer.userName === undefined || typeof peer.userName === 'string') &&
    (peer.tailscaleIPs === undefined || validStringArray(peer.tailscaleIPs)) &&
    (peer.tags === undefined || validStringArray(peer.tags));
}
export function readPeers(raw: string): PeerInfo[] {
  const result: PeersResult = JSON.parse(raw) as PeersResult;
  if (!result || result.ok !== true || !Array.isArray(result.peers)) {
    throw new Error(result?.error || '无法读取在线设备');
  }
  if (!result.peers.every((peer: PeerInfo) => validPeer(peer))) {
    throw new Error('Tailscale 设备数据格式不正确');
  }
  return result.peers.filter((peer: PeerInfo) => peer.online === true);
}
export function isAuthenticated(status: ControlResult): boolean {
  return status.ok === true && status.loggedIn === true &&
    (status.backendState === 'Running' || status.backendState === 'Starting' ||
      status.backendState === 'Stopped' || status.backendState === 'NoState');
}
export function accountName(status: ControlResult): string {
  return status.self?.userLogin || status.self?.userName || 'Tailscale 账号';
}
export function tailnetName(status: ControlResult): string {
  return status.tailnet?.magicDNSSuffix || status.tailnet?.name || '当前 Tailnet';
}
export function peerName(peer: PeerInfo): string {
  return peer.hostName || peer.dnsName || '未命名设备';
}
export function peerAddress(peer: PeerInfo): string {
  return peer.tailscaleIPs?.join(' · ') || '暂无 Tailscale IP';
}
export function osLabel(os: string): string {
  switch (os.toLowerCase()) {
    case 'windows': return 'Windows';
    case 'linux': return 'Linux';
    case 'macos': case 'darwin': return 'macOS';
    case 'ios': return 'iOS';
    case 'android': return 'Android';
    case 'openharmony': case 'harmonyos': return 'HarmonyOS';
    default: return os || '未知系统';
  }
}
export function safeOutput(raw: string): string {
  let formatted: string = raw;
  try { formatted = JSON.stringify(JSON.parse(raw), null, 2); } catch (_error) {}
  return formatted.replace(/https:\/\/login\.tailscale\.com\/[^\s"\\]+/g,
    'https://login.tailscale.com/[redacted]');
}
