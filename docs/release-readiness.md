# First release readiness

Updated: 2026-10-10, VPN Alpha 3.2.0 implementation. Login/device discovery and
basic VPN interface capabilities have phone evidence. Real TUN integration,
service ownership and main ON/OFF are now implemented and host/target verified;
**new phone traffic acceptance is still outstanding**. See [details](vpn-alpha.md).

## Confirmed scope

The user selected the functional VPN Alpha on 2026-10-10. A login-only preview
is not the release target.

The first useful VPN release is an **Alpha**: official login, existing
device discovery, and real IPv4 TCP/UDP access to Tailnet peers from other apps
through a user-authorized HarmonyOS VPN extension. Route only the supported
Tailnet destinations; preserve ordinary Internet access and existing system DNS.
Do not include exit nodes, subnet routing, MagicDNS, IPv6, always-on startup,
Taildrive, SSH server or policy-group management in the initial promise.

The interim 3.1.4 probe was phone-confirmed but did not forward packets. The new
3.2.0 switch starts the actual data path; its diagnostic remains capability-only.

## Existing evidence

- Official login and online-peer discovery were user-confirmed on a real phone
  with version 3.0.6.
- Current 3.1.0 UI/refactor has the documented 113 passing server cases and actual
  ARM64/ArkTS/HAP compilation. New UI layout/foreground behavior is not yet
  device-accepted. See `server-verification-2026-10-10.md` and `device-test.md`.
- GitHub `main` preserves the original history. The self-hosted check workflow
  is present; runner deployment and remote CI execution are not verified.
- Current signing script uses a debug key/profile outside the repository. This
  is not evidence of a generally installable public binary release.

## Remaining work and gates

| Priority | Work | Exit criterion |
| --- | --- | --- |
| P0 | Target-phone packet capability | Acquisition, access flags/protection API and cleanup passed in 3.1.4; actual read/write must be accepted in 3.2.0 |
| Implemented | Official Tailscale packet integration | Real pinned-engine IPv4 TCP/UDP packet encryption/decryption passed offline; phone OS/app flows remain unverified |
| Implemented / device pending | Physical-network exclusion, routes and FD ownership | Protected extension transport, Tailnet IPv4-only route, duplicate ownership and joined shutdown implemented; actual exclusion/routing awaits phone evidence |
| Implemented / device pending | VPN lifecycle and UI contract | Single state owner, private LocalAPI, ON/OFF/logout/reconnect and explicit uncertain cleanup implemented/tested; mobile background/revocation still pending |
| P0 | Real data-path acceptance | Another phone app reaches a Tailnet peer over TCP and UDP; direct and DERP paths, network loss/change, screen-off and stop/start behavior have evidence |
| P0 | Public artifact and install/upgrade path | Distribution channel, certificate/profile and eligible devices established; version/bundle strategy preserves intended upgrades; signed package and checksum verified |
| P0 | Release metadata and notices | Choose our own source license, review dependency licenses/notices and unofficial product naming; document supported scope, known limitations and logs/data behavior |
| P1 | Release automation and repeatability | Release-mode packaging and unambiguous versioned artifact naming; release manifest/checksums; a verified trusted CI route or recorded local full gate |
| Later | MagicDNS, IPv6, exit nodes/subnets, always-on | Each added platform capability has its own acceptance and failure behavior |

Server-first tests remain required for state transitions, packet adapter
contracts, cancellation, FD cleanup, route conversion and NAPI/UI contracts.
Only the new platform boundary and actual traffic require focused device tests;
Mock/host execution is never labelled device VPN evidence.

## Technical findings behind the order

- `core/backend.go` creates `tsnet.Server` only in discovery mode. Pinned upstream tsnet
  initializes a userspace engine without a real `Tun`, `Router` or `DNS`
  configurator and adds its own netstack. A system-VPN adapter requires a
  separate integration, now implemented in `service_backend.go`/`packet_tun.go`.
- `wgengine.Config` in pinned upstream exposes `Tun`, `Router`, `DNS` and
  `ReconfigureVPN` boundaries. The new backend supplies its real Tun and
  platform Router and starts ipnlocal directly; it does not mutate tsnet.Sys().
- The installed SDK declares `VpnExtensionAbility`, `VpnConnection.create`
  returning the vNIC FD and `protect(socketFd)` since API 11.
  `protectProcessNet()` is declared since API 22. Runtime support on our phone
  completed in the 3.1.4 phone probe; actual physical-traffic exclusion still
  needs proof. Do not require API-26 authorization observers on API 24.
- `core/runtime.go` currently disables Linux netns socket controls for the
  proven userspace login path. It is not a VPN bypass/protection adapter.
- Extension/UI ownership works with either shared or separate native processes:
  a lifetime state lease and private Unix LocalAPI prevent concurrent state opens.
- App metadata uses `com.ezoo.tailscaleprobe` and version 3.2.0. Public
  tag naming can differ, but Android-style semantic expectations must not cause
  a downgrade of the HarmonyOS versionCode; changing bundle identity also
  changes signing and app-private state/upgrade behavior.
- Existing build scripts produce debug probe-named artifacts. The fixed signed
  name is kept for the user's download workflow; older packages are backed up.
  A public release still needs its own manifest and generally usable signing.

## Implementation sequence

1. Small VPN capability proof: authorization, extension lifecycle, vNIC FD and
   physical-network protection. No claim of Tailscale traffic yet.
2. Minimal packet adapter: one peer TCP/UDP flow, then direct/DERP and stop/start.
3. Integrate the service, supported route configuration and UI state with
   server regression gates; accept network-change/background behavior on device.
4. Finalize legal/product metadata, signing/distribution, release artifacts and
   reproducible evidence; publish an explicitly scoped Alpha.

Do not spend the first milestone on cosmetic file splitting or promise stable
VPN functionality before the packet and mobile lifecycle gates pass.
