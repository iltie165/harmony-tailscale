# VPN 3.2.3 — live readiness before handoff

2026-10-12. A device user reported ON fails with the 3.2.2 saved-account
reconnecting guard. They also questioned why each VPN toggle starts a core.

## Confirmed regression and fix

The ON handler checked the rendered snapshot instead of live native status.
A stale Starting snapshot was immediately rejected. Worse, preflight failure
entered recovery that closed/restarted discovery, interrupting reconnection.

ON now reads live status and waits up to 30 seconds for authenticated Running
with a current Tailnet IPv4, showing the last state. Native status reads are
individually bounded to at most 10 seconds. Expired authentication, malformed
responses and a missing IPv4 fail explicitly. Timeout or preflight failure
does not close/restart discovery, request an extension, or mark VPN resources
as acquired. Unmount and late native results cannot initiate a later handoff.
Duplicate taps remain suppressed. Recovery after a real handoff and uncertain
VPN cleanup retains the existing owner/lease rules.

## Lifecycle design (unchanged)

OFF mode uses an app-owned tsnet discovery core; ON mode uses the extension's
official engine attached to the system TUN. ON waits for an assigned IP, closes
discovery, starts/protects the VPN interface, starts the extension core using
the same credentials, and attaches the UI to the private LocalAPI. OFF joins
the VPN engine, closes/destroys the interface, and starts discovery again.

This serial handoff prevents simultaneous owners of persisted state and
supports background VPN service execution, but it incurs core startup and
network-map resynchronization on each transition. Starting is not logout.
This release fixes premature rejection/recovery churn, **not** the ownership
architecture. Eliminating that startup cost would require a separate core/TUN
lifecycle redesign with real-device background and OFF semantics validation.
Persistent phone-side Starting was not diagnosed from a new native log here.

## Verification and delivery

`make check`: **218 passing leaf cases**, no failures/skips: 97 Go, 5 ctypes,
9 real host NAPI, 13 mock NAPI, 94 UI/VPN; offline race/vet/coverage and actual
ARM64/ArkTS/HAP validation passed (`dist/vpn-3.2.3-check.log`). UI tests execute
production methods against injected ports: stale snapshots, asynchronous
readiness, duplicate taps, timeout without restart, authentication expiry,
missing IPv4, unmount, and hung/late status reads. These are not phone evidence.

The existing signing materials and prior authorized credential were reused
transiently; no credential was newly saved. Signature/native code-sign/payload
verification passed (`dist/vpn-3.2.3-sign.log`). The old fixed 3.2.2 package was
preserved before replacing the fixed download.

- Version: **3.2.3**, code **3002003**
- Download: `dist/hap/tailscale-probe-signed.hap`
- Size: **27677001** bytes
- SHA-256: `59ef6176c82d97e3327148abd32c256f76aaf4e95e012e8982f9db8edbddc375`

Cover-install without uninstalling. Test ON immediately after reopening/OFF:
it should wait and then connect without repeated taps. Repeat Moonlight and
OFF account-preservation checks. If readiness still times out, preserve the
last native BackendState plus core status and Go logs to diagnose the actual
phone reconnection issue; do not hide it by declaring a saved account connected.
