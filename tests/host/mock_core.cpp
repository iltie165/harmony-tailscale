#include "libtailscale_ohos.h"
#include <atomic>
#include <cassert>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
namespace {
std::atomic<int> allocated{0};
char *Owned(const std::string &value) {
    allocated++;
    return ::strdup(value.c_str());
}
__attribute__((destructor)) void CheckOwnership() { assert(allocated == 0 && "NAPI leaked Go result strings"); }
}
extern "C" uint32_t tailscale_ohos_abi_version() { return 3; }
extern "C" char *tailscale_ohos_version() { return Owned("1.86.2"); }
extern "C" char *tailscale_ohos_go_version() { return Owned("go1.24.5"); }
extern "C" int tailscale_ohos_core_probe() { return 1; }
extern "C" char *tailscale_ohos_start(char *, char *host) {
    if (std::strcmp(host, "slow") == 0) std::this_thread::sleep_for(std::chrono::milliseconds(80));
    return Owned(R"({"ok":true,"operation":"start","state":"started"})");
}
extern "C" char *tailscale_ohos_status() { return Owned(R"({"ok":true,"operation":"status","backendState":"Running","loggedIn":true})"); }
extern "C" char *tailscale_ohos_login() { return Owned(R"({"ok":true,"operation":"login","authUrl":"https://login.tailscale.com/a/private-native-token"})"); }
extern "C" char *tailscale_ohos_logout() { return Owned(R"({"ok":true,"operation":"logout","loggedIn":false})"); }
extern "C" char *tailscale_ohos_close() { return Owned(R"({"ok":true,"operation":"close","state":"closed"})"); }
extern "C" char *tailscale_ohos_online_peers(char *filter) {
    if (std::strcmp(filter, "null-result") == 0) return nullptr;
    if (std::strcmp(filter, "empty-result") == 0) return Owned("");
    return Owned(R"({"ok":true,"operation":"onlinePeers","peers":[]})");
}
extern "C" char *tailscale_ohos_diagnostics(char *) { return Owned(R"({"ok":true,"operation":"diagnostics"})"); }
extern "C" char *tailscale_ohos_logs() {
    if (std::getenv("HARMONY_TEST_LONG_LOG")) {
        // A single huge newest line, ending in UTF-8 plus newline, must not
        // vanish when the forwarding logic searches for a line boundary.
        std::string text;
        for (int i = 0; i < 3000; ++i) text += "中";
        return Owned(text + " newest-marker\n");
    }
    return Owned(std::string(12000, 'x') + "\nnewest control error retained\nUTF-8: 中文\n");
}
extern "C" void tailscale_ohos_string_free(void *value) { if (value) { allocated--; std::free(value); } }
