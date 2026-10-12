# VPN first-consent startup correction

Delivery update: the user resumed packaging. Complete host/target checks and
signing/verification passed for [3.4.1](ui-3.4.1.md); phone acceptance is still
pending. The paused-build descriptions below record the earlier source-fix stage.

The user reports 3.4.0 fails to enable after tapping Allow, although earlier
warm toggles worked. The user explicitly paused builds/signing. No replacement
HAP is delivered by this change; device cause and fix acceptance remain pending.

Follow-up: the user also authorized the six audit corrections. See
[interaction review fixes](interaction-review-fixes-2026-10-12.md) for receipt
reconciliation during boot, owned-core rollback, reactive VPN state and UI flows.
Building/signing remains paused.

## Confirmed code defects and SDK boundary

- The client awaited `startVpnExtensionAbility` before reading the extension's
  `handoff_wait` acknowledgment. This makes handoff depend on SDK Promise
  settlement even when the authorized extension is already running. The account
  remains locked until the client releases it. A delayed SDK receipt can stall
  that handshake; it is not an explicit user-authorization-result callback.
- The installed SDK's `@ohos.net.vpnExtension.d.ts` documents first-start
  `Want.parameters` support **from API 22**. The old entrypoint depended only on
  `vpnMode`, `ownerId`, `hostname` and `intentId` in that Want. Parameter omission
  prevents entry into the service path. The actual phone API/Want delivery and
  SDK Promise order are not established by these host tests.

## Changes

- Observe new-owner snapshots while SDK start is pending. Only a fresh matching
  owner acknowledgment begins the 30-second handoff/connection budget and
  releases the unknown-start lease. Missing acknowledgments remain bounded by
  the separate 60-second startup/authorization wait. Pending SDK calls without
  an acknowledgment still retain their lease until settlement after cancellation.
- Persist a private atomic bootstrap request before the SDK start. A
  parameterless extension launch can use it only with a current enabled intent,
  matching revision, valid schema, age no greater than 90 seconds, and no
  previously consumed snapshot for that owner. Explicit diagnostic requests
  do not fall through to product boot. No credentials or auth URLs are stored.
- Preserve two-phase ownership: only authorized `handoff_wait` permits release
  of the foreground account host, followed by an owner/revision-bound command.
  OFF/denial/expired requests do not hand off or acquire a TUN.
- Warm toggles reuse the healthy extension/core and invoke neither SDK start
  nor SDK stop. The app adds no ON confirmation dialog and does not manufacture
  or bypass OS authorization. Initial progress is neutral, not an unconditional
  instruction to authorize on every toggle. Login never starts the extension.
- Retain the pending original-PNG icon, authenticated-notice cleanup and stable
  observed-device-row/silent refresh changes. Correct two unfinished projection
  helpers found by UI regressions before any packaging.

## Verification boundary

Run `scripts/check-source.sh` and `scripts/test-ui.sh` without target/host native
build or signing. Evidence: `dist/vpn-consent-ui.log`.

Runtime regressions exercise the production client and actor together with a
fake SDK receipt that resolves only when the TUN is created: release, boot,
create, protect, attach complete without waiting for that receipt first.
Other regressions cover omitted first-consent Want parameters via production
platform/store/ability code, cancellation, denial, consumed/expired/replaced
intent, late receipts and warm ON/OFF retention. These do not prove phone
authorization callbacks, ArkTS compilation, sandbox startup or real traffic.

Target `make check`, packaging/signing and actual phone Allow/deny/cancel,
warm ON/OFF, device identity and Moonlight verification are intentionally
deferred until the user resumes building. Go/Tailscale, dependencies, images,
permissions and signing configuration are unchanged.
