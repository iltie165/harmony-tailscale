# VPN 3.2.4 — display restoration independent of live connectivity

2026-10-12. This maintenance release separates saved display metadata, live
account authentication, peer freshness and independently confirmed VPN state.

## Product changes

- After one successful account synchronization on this version, the next cold
  launch paints the saved account/devices before native startup completes.
  The account is labelled saved/unverified until official status arrives.
- `SessionPreview.ets` stores only whitelisted account/peer metadata in the
  app-private `tailscale-display.json`, using atomic replacement. No login URL,
  credential, key, log, authentication flag or VPN connection state is cached.
  Malformed/oversized caches are ignored. Persistence failure does not fail
  the live connection. Filtered results are not cached as the complete list.
- VPN startup still requires live official authentication, Running and an
  assigned IPv4. A cached account/IP is never sufficient. NeedsLogin,
  NeedsMachineAuth and successful explicit logout invalidate the display cache.
  Account/Tailnet changes clear the previous devices before synchronization.
- Temporary reconnection and query failure retain historical devices/details
  with stale labels and the previous update timestamp. They do not advertise
  those cached devices as currently online. A successful empty query remains a
  genuine empty list; a query error remains visibly an error.
- Foreground saved/live accounts synchronize silently every five seconds even
  with VPN OFF. Background entry stops page timers; returning refreshes and
  resumes polling. This does not stop the extension's packet path.
- Once the owner independently confirms VPN ON, a peer query failure only
  reports incomplete device synchronization; it does not claim VPN failed or
  invent a cleanup requirement. After confirmed OFF, a device query failure
  does not undo the teardown result.
- The diagnostic close action pauses the connection while retaining account
  display/history; it does not invent a signed-out state or automatically
  restart the deliberately paused core. Explicit start resumes synchronization.
- Settings reads the installed bundle version instead of a stale literal.

## Deliberate lifecycle boundary

This release does **not** implement a permanent cross-process core, detachable
TUN, system-reclaim prevention, automatic process resurrection or new reconnect
timeouts. The discovery-to-extension core handoff and existing state lease,
socket IPC, process protection, routing and packet implementation are unchanged.
Showing the page earlier is not a claim that native startup/control synchronization
is faster. First upgrade needs live synchronization to seed the display cache.

## Verification

The complete offline `make check` exercises production page methods and the
real cache codec/storage calls against injected ports, alongside existing Go
race/vet/coverage, actual Linux C ABI/NAPI and HarmonyOS ARM64/ArkTS/HAP gates.
Final `make check`: **230 passing leaf cases**, zero failures/skips: 97 Go,
5 ctypes, 9 real host NAPI, 13 mock NAPI, and 106 UI/VPN cases.
Evidence: `dist/vpn-3.2.4-check.log`. These are not device rendering/background
or packet-flow acceptance results.

Phone acceptance: cover-install without uninstalling; synchronize once; close
and reopen both online/offline; verify saved-account and historical-device
labels; verify explicit logout and authentication expiry return to login;
repeat ON/OFF and Moonlight streaming; check OFF-mode automatic device updates
and background/foreground behavior. No change to the earlier separate reverse
ping, network-transition, screen-off and system-reclaim acceptance boundaries.

Version: **3.2.4**, code **3002004**. Existing signing materials and the prior
authorized credential were reused transiently, without newly persisting the
password. Signature/native code-sign/payload verification passed; evidence:
`dist/vpn-3.2.4-sign.log`. The previous fixed 3.2.3 package was backed up.

- Fixed signed download: `dist/hap/tailscale-probe-signed.hap`
- Size: **27702124 bytes**
- SHA-256: `1f20cc4349aa9c22a1148cc1fd37808786912d109cc0cc07079dad0f189860f4`
