# 3.3.0 — unified-core architecture Alpha

## Product lifecycle

| Action | Core | Platform VPN interface |
| --- | --- | --- |
| Fresh install/open | No automatic bootstrap before login | None |
| Login/saved-account restoration | Start extension service once, or connect to a healthy existing owner | None; system service authorization may appear |
| VPN ON | Reuse existing official engine; wait for live auth/assigned IPv4/Running | Create /32 and Tailnet-only route, protect process, duplicate and attach FD, close original |
| VPN OFF | Retain engine, account, control connection, state lease and Unix LocalAPI | Detach/join duplicated FD, close original if pending, destroy SDK network |
| Page disappears/background | Stop UI observers/queries; accepted service intent continues | Unchanged |
| Logout | Disconnect real VPN first; explicitly revoke auth | Destroyed before logout |
| Deliberate diagnostic service stop | Close engine after interface cleanup, then stop extension; keep account credentials | Destroyed |
| Confirmed dead core / process loss | Recover a new generation; never assume old snapshot proves healthy | Recovery starts OFF; user enables again |

Normal ON/OFF no longer performs discovery/VPN core handoff. The permanent
logical TUN stays alive; it drops incoming system-bound traffic while detached
and does not answer local ping while OFF. No packet queue is replayed into a
later interface. Cumulative counters survive normal OFF/ON. Legacy tsnet/one-shot
exports remain for compatibility and diagnostic tests, not the product path.

## State and ownership

- The page renders `ClientView`; shared `ClientController` owns account/display/
  query state. It cannot close the service just because a view disappears.
- `NetworkServiceClient` serializes intents, tracks unresolved SDK calls, verifies
  native core ID/health and rejects stale owner/command generations.
- The extension actor alone creates/protects/attaches/detaches/destroys resources.
  It checks cancellation after each await and reports incomplete cleanup.
- An exclusive app-private file lease prevents duplicate official state owners.
  UI native clients connect only to the Unix LocalAPI: missing service never
  falls back to creating a discovery core. Disconnecting a UI client cannot
  stop an in-process service owner.
- Local account metadata remains display-only, not an authorization source.
  SDK protection, live official authentication and native attachment are all
  required before reporting connected. Control reconnection/Starting alone
  does not stop a healthy engine; the old 90-second teardown is removed.
- Old own-app network cleanup is attempted only after the new host confirms
  exclusive native ownership. Failed destroy/FD close remains cleanup_pending.

## HarmonyOS boundary

The official SDK's generic AppServiceExtensionAbility is restricted to PC/2in1
and an enterprise ACL; it is not a normal phone background service. This build
uses VpnExtensionAbility as the host. Published OpenHarmony networkvpn code
distinguishes connection `destroy()` from stopping the extension ability, but
that source behavior is **not proof of Huawei phone firmware residency**.

Normal OFF intentionally does not call stopVpnExtensionAbility. The system may
still stop/freeze the extension, including when its associated UI process dies.
There is no promise of an immortal singleton or workaround disabling system
resource policies. Keeping the core while OFF costs background resources.
No evidence establishes that high traffic by itself is the reason for a system
stop. Diagnostics record explicit stop callbacks/errors; sudden killing leaves
an uncertain stale snapshot, not a fabricated reason.

Reference sources:

- Huawei SDK declarations: `@ohos.app.ability.AppServiceExtensionAbility.d.ts`
  and `@ohos.net.vpnExtension.d.ts` from the existing target SDK, inspected for
  device/ACL restrictions and separate create/destroy/start/stop APIs.
- [OpenHarmony NetworkVpnService](https://github.com/openharmony/communication_netmanager_ext/blob/master/services/vpnmanager/src/networkvpn_service.cpp)
- [OpenHarmony NetVpnImpl](https://github.com/openharmony/communication_netmanager_ext/blob/master/services/vpnmanager/src/net_vpn_impl.cpp)

## Verification and phone acceptance

Server tests execute the real official local control server and TLS DERP,
register a saved profile and perform three real attach/detach cycles. They verify
one core ID, one registered node, held state lease and unchanged account keys.
Two actual upstream engines also exchange encrypted TCP/UDP IPv4 packets through
the production detachable adapter after repeated OFF/ON; OFF inbound packets
and local ICMP replies are dropped. ACL-denied ping remains denied.

Production actor/client/controller regressions exercise late SDK completion,
OFF during create, stale heartbeat with healthy core, wrong generation,
protection/detach/destroy/FD-close/storage faults, real-engine death, resource
uncertainty after page restoration, and page disposal during an accepted intent.
The final check log is `dist/refactor-check.log`; signing has separate evidence.
These host tests and ARM64/ArkTS/HAP compilation do not prove phone SDK behavior.

Final `make check`: **251 passing leaf cases**, zero failures/skips (102 Go,
6 ctypes, 9 real NAPI, 13 mock NAPI, 121 controller/service/VPN cases). Race,
vet, measured business-domain coverage, ARM64, ArkTS and HAP gates passed.
Signed versionCode is `3003000`; all packaged native code signatures and the
permission signature verified. Signed HAP is 27,799,137 bytes, SHA-256:

```text
f1500169e8aea004e85e783064eee9c9aae354af4a9fd67c4692918e89784c4a
```

Evidence: `dist/vpn-3.3.0-sign.log`, `dist/vpn-3.3.0-payload.log` and
`dist/hap/vpn-alpha-manifest.json`. The previous 3.2.4 package is preserved as
`dist/hap/tailscale-probe-3.2.4-signed.hap`; the fixed delivery filename remains
`tailscale-probe-signed.hap`.

Phone acceptance (cover install; do not uninstall/erase account):

1. Close old VPN first; update and restore existing account. First service
   authorization may appear. Confirm toggle OFF does not route traffic.
2. Open diagnostics/status and note coreId/startedAt. Repeat ON/OFF three times;
   both values should stay unchanged while the extension remains alive.
3. With ON, verify Moonlight, PC-to-phone Tailnet ping, ordinary internet and
   TCP/UDP. With OFF, Tailnet application traffic and phone ping should stop,
   while account/devices remain visible.
4. Return home/reopen page, then screen-off/background and Wi-Fi/cellular switch.
   Capture diagnostics if interrupted. System termination can require recovery;
   a new generation must be visible and must not silently enable an old intent.
5. Explicit logout must end VPN first and stay logged out on relaunch. Cancel or
   deny authorization and verify no false connected state or lost credentials.

Compatible SDK remains `6.1.1(24)`; target is API 26. Compilation is not HarmonyOS
7.0 runtime acceptance. Device model/profile signing restrictions still apply.
