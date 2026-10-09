#include "libtailscale_ohos.h"

extern "C" int harmony_tailscale_native_smoke() {
  const uint32_t abi = tailscale_ohos_abi_version();
  const int core_present = tailscale_ohos_core_probe();

  char* tailscale_version = tailscale_ohos_version();
  char* go_version = tailscale_ohos_go_version();
  char* status = tailscale_ohos_status();
  char* login = tailscale_ohos_login();
  char* logout = tailscale_ohos_logout();
  char empty_filter[] = "";
  char* peers = tailscale_ohos_online_peers(empty_filter);
  char* logs = tailscale_ohos_logs();
  tailscale_ohos_string_free(tailscale_version);
  tailscale_ohos_string_free(go_version);
  tailscale_ohos_string_free(status);
  tailscale_ohos_string_free(login);
  tailscale_ohos_string_free(logout);
  tailscale_ohos_string_free(peers);
  tailscale_ohos_string_free(logs);

  return abi == 3 && core_present == 1 ? 0 : 1;
}
