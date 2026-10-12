import { deviceInfo } from '@kit.BasicServicesKit';
import tailscale from 'libtailscale_napi.so';

export class PlatformInfo {
  os: string = 'openharmony';
  osVersion: string = '';
  deviceModel: string = '';
}
function clean(value: string): string { return value.replace(/[\u0000-\u001f\u007f]/g, '').trim().slice(0, 128); }
export function readPlatformInfo(): PlatformInfo {
  const info = new PlatformInfo();
  let fullName: string = '';
  let display: string = '';
  try { fullName = clean(deviceInfo.osFullName); } catch (_error) {}
  try { display = clean(deviceInfo.displayVersion); } catch (_error) {}
  try { info.deviceModel = clean(deviceInfo.productModel); } catch (_error) {}
  const name = /^(OpenHarmony|HarmonyOS)[ -](.+)$/i.exec(fullName);
  if (name) {
    info.os = name[1].toLowerCase();
    if (/\d/.test(name[2])) { info.osVersion = name[2]; }
  }
  if (!info.osVersion && /\d/.test(display)) { info.osVersion = display; }
  // Unknown versions remain unknown; never substitute a build SDK version or
  // a Linux kernel release. No serial, UDID or account data is collected.
  return info;
}
interface PlatformResult { ok: boolean; error?: string; }
export async function configurePlatformInfo(): Promise<void> {
  const result = JSON.parse(await tailscale.configurePlatform(JSON.stringify(readPlatformInfo()))) as PlatformResult;
  if (!result.ok) { throw new Error(result.error || '无法配置系统信息'); }
}
