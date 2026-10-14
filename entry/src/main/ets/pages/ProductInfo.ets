// User-facing release scope and a whitelist-only, local support summary.
export interface HelpSection { title: string; body: string; }
export const HELP_SECTIONS: HelpSection[] = [
  { title: '开始使用', body: '先通过系统浏览器登录 Tailscale，返回应用检查登录结果。管理员审批未完成时需要等待管理员批准。登录不会开启 VPN。' },
  { title: '连接设备', body: '在首页开启 VPN；系统要求授权时选择允许。打开设备详情复制 IPv4，再在浏览器、远程桌面或 Moonlight 等应用中使用该地址和服务端口。目标设备必须在线，并允许对应服务访问。' },
  { title: '地址与访问范围', body: '首版仅支持 Tailnet IPv4，不接管普通上网或系统 DNS。请使用 100.x IPv4，不依赖 DNS 名称；MagicDNS、IPv6、出口节点、子网路由和开机自启尚未支持。' },
  { title: '连接失败怎么办', body: '先确认账号已认证、目标设备在线且服务正在监听，再检查访问策略和对端防火墙。VPN 开关已开启不等于目标服务可达。系统拒绝授权时可重试；清理未完成时先重试关闭，不要重复开启。' },
  { title: '网络切换与后台', body: '切换 Wi-Fi/蜂窝或断网后等待恢复，再重试目标应用。系统可能暂停或结束后台服务；若未恢复，返回首页查看状态并显式重试连接。不要把历史设备记录当作实时在线状态。' },
  { title: '升级与反馈', body: '升级前关闭 VPN，使用签名兼容、升级序号更大的包覆盖安装，不要先卸载。卸载可能丢失账号状态。诊断页可查看并复制不含账号、IP 和原始日志的反馈摘要；提交反馈前仍应核对内容。' }
];
export const PRIVACY_TEXT: string = '账号与节点凭据保存在应用私有目录。关闭 VPN 保留登录；退出登录会注销该设备，卸载可能删除本地状态。登录和连接会与 Tailscale 上游服务通信，网络诊断会进行连通性检查。反馈摘要在本机生成，不自动上传；只有点击复制才写入剪贴板。原始诊断日志可能包含设备与网络信息，分享前请自行核对。';
export function projectLink(kind: string): string {
  switch (kind) {
    case 'source': return 'https://github.com/iltie165/harmony-tailscale';
    case 'issues': return 'https://github.com/iltie165/harmony-tailscale/issues/new/choose';
    case 'releases': return 'https://github.com/iltie165/harmony-tailscale/releases';
    case 'privacy': return 'https://tailscale.com/privacy-policy/';
    default: throw new Error('未知项目链接');
  }
}
export interface SupportSummaryInput {
  version: string;
  os: string;
  osVersion: string;
  authenticated: boolean;
  backendState: string;
  vpnState: string;
  connected: boolean;
  coreAlive: boolean;
  peersStale: boolean;
  peerCount: number;
}
function plain(value: string): string { return value.replace(/[\u0000-\u001f\u007f]/g, '').slice(0, 96); }
export function supportSummary(input: SupportSummaryInput): string {
  const version = /^\d+\.\d+\.\d+(?:-(alpha|beta|rc)\.\d+)?$/.test(input.version) ? input.version : '未知';
  const backend = ['Running', 'Starting', 'NeedsLogin', 'NeedsMachineAuth', 'Stopped', 'NoState'].includes(input.backendState) ? input.backendState : '未知';
  const vpn = ['connected', 'disconnected', 'connecting', 'reconnecting', 'error', 'cleanup_pending'].includes(input.vpnState) ? input.vpnState : '未知';
  const count = Number.isInteger(input.peerCount) && input.peerCount >= 0 ? input.peerCount : 0;
  return `harmony-tailscale 反馈摘要\n应用：${version}\n系统：${plain(input.os)} ${plain(input.osVersion)}\n账号已认证：${input.authenticated ? '是' : '否'}\n账号状态：${backend}\nVPN 状态：${vpn}\n接口已连接：${input.connected ? '是' : '否'}\n核心存活：${input.coreAlive ? '是' : '否'}\n设备数量：${count}（${input.peersStale ? '历史记录' : '最近同步'}）\n\n不含账号、Tailnet 名称、IP、节点标识、登录链接或原始日志。\n请补充复现步骤、预期与实际行为。`;
}
