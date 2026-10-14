# 3.4.0 — Browser login and explicit VPN authorization

> 历史内部测试包记录：本文 2.x/3.x 编号不是正式发行版本。当前版本见
> [版本规范](../versioning.md)，旧包证据保留原样。

## Product behavior

- Clean install shows welcome without requesting system VPN permission.
- Login starts an explicit permission-free foreground wgengine/ipnlocal host,
  gets an official authentication URL and opens the browser. Successful account
  confirmation enters the dashboard independently of Running/DERP/peer lists.
  Browser observation has a cancel action; no automatic browser reopening.
- Saved-account restoration uses the account host or an existing healthy
  extension. No startup overlay waits for remote synchronization.
- Explicit ON alone can invoke the VPN extension authorization API. Connection
  has local progress, cancellation and retry; desired ON is not rendered as
  established. Denial retains login. Manual failure cancels persisted ON rather
  than starting unlimited background retries.
- Device refresh has independent loading/error fields, retains labelled
  historical devices and cannot monopolize VPN/diagnostic controls.
- OFF cancels pending/recovery intent before any waits, cleans interface
  resources and retains the account/warm extension core. Cleanup uncertainty
  gets an explicit retry-close action. Logout cancels VPN then explicitly revokes
  account state; late responses cannot repaint the old account.
- Recovery can repair an existing host/interface, but absent-host recovery
  pauses for explicit ON. This intentionally trades cold auto-restart for
  never presenting a system authorization dialog without user action.

## Core ownership and handoff

The new additive C ABI/NAPI startAccount and releaseAccount operations use the
same official serviceBackend with a foreground role, rather than silently
falling back to tsnet. Foreground has a detached logical TUN, the same exclusive
state lease, platform metadata and private LocalAPI, but no system VPN SDK use.
The host role is exported in independent native VPN state.

After consent, the new extension actor publishes handoff_wait without booting
or writing credentials. The client then releases only the foreground owner
and acknowledges handoff using the new owner ID and persisted intent revision.
The actor must verify both before loading the same tailscaled.state. Refusal,
wrong generation/revision, failed release and cancellation cannot grant boot.
The account release API cannot close an extension or its remote UI proxy.
Normal warm ON/OFF still attaches/detaches TUNs in one extension-owned engine.

Queries now have shared read leases and cancellable native contexts. Resource
mutations cancel reads before obtaining the exclusive operation lock, preserving
Start/Close safety without a slow device read blocking shutdown. Status/peers
are bounded natively; browser-URL observation is bounded to 15 seconds. Consent
has its own bounded pending SDK lease; after SDK acknowledgment, local handoff
and TUN setup share a 30-second connection window. Unresolved SDK work keeps
its lease after UI cancellation and cannot authorize a later stale attempt.

## Verification evidence

Evidence: dist/ui-3.4.0-check.log, dist/ui-3.4.0-build.log,
dist/ui-3.4.0-sign.log, dist/tests/go.jsonl and coverage-summary.json.

Final unique checks: 314 passing leaf cases, zero failures/skips (110 Go,
6 ctypes, 11 real loaded host NAPI, 14 mock NAPI, 173 UI/service/recovery).
Complete make check contains the 313-case baseline plus ARM64/ArkTS/HAP gates;
dist/redesign-ui-final.log adds the final rejected-boot ownership regression.
Signing verifies the platform signature, permissions and packaged native libs;
the signed payload must exactly match the previously verified unsigned build.

The real local encrypted official control server receives a foreground node,
then the extension restarts from its persisted profile without interactive
login. NodeID, node public key, assigned IP and control.NumNodes()==1 survive
the handoff. With no peer/DERP, the actual core remains Starting and can still
attach the authorized TUN. Real loaded host NAPI exercises account startup,
the pre-handoff VPN guard, release and extension-owner retention. Existing
encrypted packet/OFF/ON, ACL/ICMP and upstream registration regressions remain.

Runtime UI/actor/recovery tests cover browser-only login, independent device
refresh, permission denial, owner/revision handshake, failed account release,
late authorization after cancellation, logout during consent and native query
cancellation. Actual ARM64 ELF/TLS/exports, ArkTS and HAP payload checks are
required before release. These are host/target checks, not phone evidence.

No Go/Tailscale, dependency/image, signing configuration, permission or
default-route/DNS behavior change. The latest original dark PNG is retained.

## Phone acceptance — pending

Cover-install after closing VPN in the app; do not uninstall unless deliberately
testing a clean install. A clean-install scenario loses credentials by design.

1. Fresh install or a deliberately logged-out account: Login opens only the
   official browser, with no system VPN permission prompt.
2. Return from browser: dashboard appears with VPN OFF; list loads separately.
3. First ON requests system consent, then confirms the actual interface. Reject
   once and retry: account/identity remain; no automatic repeated prompt.
4. Cancel consent/setup, including a late Allow result: no unexpected interface.
5. Slow/failed list query: ON/OFF/settings/diagnostics remain operable. Verify
   empty Tailnet, offline labels and device filtering.
6. Across first handoff and three warm ON/OFF cycles, confirm one admin-console
   node and unchanged node/IP; core ID may change at first transfer, not normal
   toggles. Check Moonlight and PC ping/ACL regression.
7. Reopen while OFF: no permission prompt. Reopen with lost background host:
   show a reconnect action, never claim automatic runtime immortality.
8. Logout during consent/connection and reopen: no restored unwanted VPN/account.

Phone SDK prompt timing, sandbox process behavior, extension residency and
real FD/packet operation remain separately unverified until these tests are run.
