# VPN 3.2.2 — persisted account restoration

2026-10-12. The user reported that reopening a logged-in app shows the login
page until tapping Login, and that VPN OFF appears to log the account out.

## Root cause and fix

The app previously defined authentication as `BackendState == Running`.
Startup and the OFF handoff restart discovery asynchronously, so a transient
NoState/Starting/Stopped snapshot incorrectly selected the signed-out page.
OFF already avoided Logout, but did not schedule account restoration polling.

- During supported restart states, query the owner's official LocalAPI prefs.
  `Persist.NodeID` plus `!LoggedOut` identifies a saved registered account.
  GetPrefs intentionally strips private keys; a generated key or a state file
  alone is not evidence of a saved account. NeedsLogin/NeedsMachineAuth remain
  unauthenticated, and query failures remain errors. No credentials cross NAPI.
- Initially show an account-restoration view instead of flashing the login page.
  Saved accounts select the dashboard even before the engine is Running.
- VPN OFF stops only the VPN owner, retains credentials, restarts discovery,
  and silently refreshes while reconnecting. Account reconnection continues
  after the initial 15-second fast-poll window, without global loading.
- Only query online peers and enable VPN startup after Running. Do not imply
  a saved login is a live connection or retain stale online-device claims.
- Explicit logout and expired authentication still select the signed-out page.

## Verification

`make check`: **213 passing leaf cases**, zero failed/skipped: 97 Go, 5 ctypes,
9 real host NAPI, 13 mock NAPI, 89 UI/VPN. Offline race/vet, coverage and real
HarmonyOS ARM64/ArkTS/HAP gates passed (`dist/vpn-3.2.2-check.log`).

The real official profile store, VPN backend, and production leased tsnet
factory were exercised offline: OFF and two discovery startups preserve the
stored node key and registered profile. UI regressions exercise cold launch
before Running, reconnection beyond 15 seconds, OFF during asynchronous restart,
no implicit browser/login/logout, readiness gating, and explicit expiry/logout.
Go-produced restored-account JSON is consumed by the actual UI decoder.

Signing reused the previously supplied password transiently with the existing
device-bound signing materials. Signature, native code-sign and HAP payload
checks passed (`dist/vpn-3.2.2-sign.log`); no credential was newly persisted.

- Download: `dist/hap/tailscale-probe-signed.hap`
- Version: **3.2.2**, code **3002002**
- Size: **27667986** bytes
- SHA-256: `2c41df8aba3c5a96275c9c3ee6afc1b73919834d031bf5cc1d6b6d1b08caccc3`

## Phone acceptance (pending)

Cover-install, do not uninstall. Confirm 3.2.2, then reopen the logged-in app
with VPN OFF and ON: both should restore the dashboard without tapping Login
or opening a browser. Turn VPN OFF, wait for device sync, and reopen again:
the account remains visible and VPN remains OFF. Then turn VPN ON and repeat
Moonlight to check packet-path regression. Explicit logout should still require
authentication. These phone results are not claimed by the host/build gates.
