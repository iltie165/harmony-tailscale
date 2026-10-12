# 3.3.3 — Platform reporting and startup readiness

## Platform metadata

The owning VPN extension reads BasicServicesKit `deviceInfo.osFullName`,
`displayVersion` and `productModel` before starting its official core. The
async NAPI/C bridge validates that metadata and configures a once-registered
upstream Hostinfo hook. OS/OSVersion/DeviceModel override Linux-compatible Go
defaults; Linux distro/container metadata is cleared. The upstream Tailscale
version, Go version, saved profile, hostname and node identity remain unchanged.
No SDK release or screenshot version is hardcoded; unavailable versions stay
unknown. No serial, UDID, new permissions or dependencies are used. Metadata
changes on a live core are rejected rather than silently promising an update.

## Startup experience

Cached account and peer data remain display-only. A full-page blocking overlay
is shown while the startup service and account connection are checked, including
when saved login is reported with `Starting`. The gate completes on a live
authenticated `Running` result with a Tailnet IPv4, or releases to the login
screen when credentials need login/machine approval. Missing IPv4 never enables
VPN. A peer-list failure after readiness does not revoke readiness.

After 30 seconds or a real startup/query error, the overlay changes to a failure
view with retry, diagnostics and display-only browsing. A late successful live
result still releases it. Retry resets the gate without forcing a healthy core
restart. A still-pending platform operation keeps retry disabled until it
settles; diagnostics/browsing remain reachable. Page disposal clears the gate's
timer without stopping runtime recovery or VPN commands.

After initial readiness, temporary control reconnections do not reintroduce a
global overlay. ON is disabled when core/IP readiness is missing; OFF remains
available for wanted/active/uncertain VPNs. Normal toggles and the recovery
supervisor retain their existing lifecycle and credential guarantees.

## Verification

Complete `make check`: 285 passing leaf cases, no failures or skips (103 Go,
6 ctypes, 10 real host NAPI, 14 mock NAPI, 152 UI/platform/VPN). The real local
encrypted upstream control server receives OpenHarmony OS, version and model,
and still registers only one node across three TUN toggles. Platform runtime
mocks verify system API extraction, inaccessible-property fallback and
configuration-before-service-start. Startup regressions cover cached display,
Starting, missing IPv4, auth/machine denial, timeouts/retry/late success, query
errors and post-readiness reconnection. ARM64/ArkTS and HAP payload gates pass.

Evidence: `dist/ui-3.3.3-check.log`, `dist/tests/*`. Tailscale remains 1.86.2 and
the toolchain remains Go 1.24.5. No dependency, image or signing config changes.
The 3.3.3 / 3003003 HAP is signed and verify-app/native/permission verification
passed (`dist/ui-3.3.3-sign.log`). The fixed download name is retained, and
the prior signed 3.3.2 is preserved. Existing authorized signing credentials
were reused only in the signing process environment, not newly persisted.

## Phone acceptance (pending)

Close VPN in the app and cover-install without uninstalling. Confirm cold
launch shows the readiness overlay, then enables the VPN switch once ready.
Test with physical networking unavailable: failure actions appear and restored
networking releases the gate. Test actual expired/approval-required accounts,
background-return handling, and top/bottom safe-area rendering. Existing live
VPNs must still allow OFF during reconnect. Verify management-console metadata
after the extension restarts and synchronizes, without an IP/node identity
change. Build and offline tests do not prove the actual system API values,
phone visual/touch behavior or hosted console rendering.
