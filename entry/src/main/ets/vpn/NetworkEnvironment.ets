import { connection } from '@kit.NetworkKit';
import { serviceDeadline } from './NetworkServiceClient';

export class NetworkEnvironment {
  online: boolean = false;
  ownVpn: boolean = false;
  otherVpn: boolean = false;
}
// Query OS-visible interfaces, not cumulative packet counts or a cached native
// attachment flag. Unknown VPNs are never destroyed to make room for recovery.
export async function inspectNetworks(ipv4: string): Promise<NetworkEnvironment> {
  return serviceDeadline(readNetworks(ipv4), 3000, '检查系统网络');
}
async function readNetworks(ipv4: string): Promise<NetworkEnvironment> {
  const result = new NetworkEnvironment();
  const nets = await connection.getAllNets();
  for (const net of nets) {
    const caps = await connection.getNetCapabilities(net);
    if (caps.bearerTypes.includes(connection.NetBearType.BEARER_VPN)) {
      const props = await connection.getConnectionProperties(net);
      if (ipv4 && props.linkAddresses.some((address: connection.LinkAddress) => address.address.address === ipv4)) {
        result.ownVpn = true;
      } else { result.otherVpn = true; }
    } else if (caps.networkCap?.includes(connection.NetCap.NET_CAPABILITY_INTERNET)) { result.online = true; }
  }
  return result;
}
