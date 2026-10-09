#include "libtailscale_ohos.h"

extern "C" int harmony_tailscale_native_smoke() {
  const uint32_t abi = tailscale_ohos_abi_version();
  const int core_present = tailscale_ohos_core_probe();

  char* tailscale_version = tailscale_ohos_version();
  char* go_version = tailscale_ohos_go_version();
  tailscale_ohos_string_free(tailscale_version);
  tailscale_ohos_string_free(go_version);

  return abi == 1 && core_present == 1 ? 0 : 1;
}
