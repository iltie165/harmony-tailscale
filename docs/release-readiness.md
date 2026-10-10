# First release readiness

Assessment: 2026-10-10, source baseline `e7265d4`. This is a plan, not
verification of new functionality. No VPN implementation or new device evidence
was produced by this assessment.

## Confirmed scope

The user selected the functional VPN Alpha on 2026-10-10. A login-only preview
is not the release target.

The first useful VPN release is an **Alpha**: official login, existing
device discovery, and real IPv4 TCP/UDP access to Tailnet peers from other apps
through a user-authorized HarmonyOS VPN extension. Route only the supported
Tailnet destinations; preserve ordinary Internet access and existing system DNS.
Do not include exit nodes, subnet routing, MagicDNS, IPv6, always-on startup,
Taildrive, SSH server or policy-group management in the initial promise.

The interim capability probe retains the disabled VPN switch and clearly states
that it cannot provide system VPN connectivity. See [probe acceptance](vpn-capability-probe.md).

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
| P0 | Validate VPN extension/TUN capability on the target phone | User consent, create/read/write/destroy vNIC, denial and resource cleanup verified on API 24 |
| P0 | Choose and implement Tailscale packet integration | Real TUN packets reach the pinned official engine; no assumption that existing tsnet login provides a system tunnel |
| P0 | Physical-network exclusion, routes and FD ownership | Control/DERP/discovery traffic avoids recursive VPN routing; supported peer routes installed; descriptors have explicit ownership and failure cleanup |
| P0 | VPN service lifecycle and UI contract | Core has one authoritative owner; UI reopening does not start a duplicate node; connect/disconnect/revoke/logout failures are explicit; login and tunnel state stay distinct |
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

- `core/backend.go` currently creates `tsnet.Server`. Pinned upstream tsnet
  initializes a userspace engine without a real `Tun`, `Router` or `DNS`
  configurator and adds its own netstack. A system-VPN adapter requires a
  separately validated integration, not just enabling the UI switch.
- `wgengine.Config` in pinned upstream exposes `Tun`, `Router`, `DNS` and
  `ReconfigureVPN` boundaries. They are candidate integration points, not a
  completed design. Prefer a platform backend behind our existing ports; do
  not blindly mutate `tsnet.Server.Sys()`, which upstream calls unstable.
- The installed SDK declares `VpnExtensionAbility`, `VpnConnection.create`
  returning the vNIC FD and `protect(socketFd)` since API 11.
  `protectProcessNet()` is declared since API 22. Runtime support on our phone
  still needs proof; do not require the API-26 authorization observer on API 24.
- `core/runtime.go` currently disables Linux netns socket controls for the
  proven userspace login path. It is not a VPN bypass/protection adapter.
- Decide whether the VPN extension shares a process with the UI. A native
  singleton is process-local; separate processes need explicit ownership/IPC
  and must not concurrently open the same Tailscale state directory.
- App metadata still uses `com.ezoo.tailscaleprobe` and version 3.1.0. Public
  tag naming can differ, but Android-style semantic expectations must not cause
  a downgrade of the HarmonyOS versionCode; changing bundle identity also
  changes signing and app-private state/upgrade behavior.
- Existing build scripts produce debug probe-named artifacts. A release must
  not accidentally attach the old generic signed 3.0.6 package as current.

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
