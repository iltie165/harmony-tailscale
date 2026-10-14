# VPN Alpha — 3.2.0

Current architecture: [permission-free account host and explicit VPN handoff](../architecture.md).
Current maintenance version: [3.4.1](../releases/ui-3.4.1.md).
Historical architecture: [3.3.0 unified service/core](../releases/vpn-3.3.0.md). The discovery/
VPN handoff and OFF engine shutdown described below are historical 3.2.x behavior.

Previous maintenance release: [3.2.4 display/connection separation](../releases/vpn-3.2.4.md), following
[3.2.3 live readiness](../releases/vpn-3.2.3.md),
[3.2.2 account restoration](../releases/vpn-3.2.2.md) and
[3.2.1 ICMP/UI fixes](../releases/vpn-3.2.1.md). On 2026-10-12
the user confirmed phone-to-home-PC Moonlight streaming works with the system
VPN. The original release evidence below remains historical; reverse ping and
the new rendering changes have separate phone acceptance steps.

Implemented on 2026-10-10. This is a **device-test build**, not a claim that the
new system data path has already passed phone acceptance.

## Product behavior

- Official browser login and all online peers visible under the Tailnet ACL.
- Main VPN switch starts the user-authorized extension and attaches its actual
  vNIC to the pinned Tailscale v1.86.2 WireGuard engine.
- IPv4 `100.64.0.0/10` route, the node's assigned `/32`, MTU 1280. No default
  route, DNS override, exit node, advertised subnet, or IPv6 platform route.
- `protectProcessNet()` precedes engine construction; Linux netns hooks remain
  disabled. SDK network events notify the official netmon for rechecks/rebinds.
- OFF stops the engine, closes descriptors, destroys the connection, then
  resumes discovery without calling Logout. Explicit logout first disconnects.
- Reconnecting remains an active, stoppable session. Unconfirmed cleanup is
  visible and retryable, including on the signed-out screen. Authenticated does
  not mean VPN connected; connected does not certify a successful peer flow.

## Ownership and packet integration

In discovery mode the existing tsnet adapter owns `tailscaled.state`. It does
not provide system packet forwarding. Before VPN startup it is fully closed.
The extension creates the interface, protects transport, and constructs the
official `wgengine` + `ipnlocal` backend using the same OS-neutral state profile.
The official control plane still configures peer keys, ACL filters, direct
transport and DERP; no permissive production filter or replacement protocol is
used. CorpDNS and RouteAll are explicitly disabled for this Alpha.

A lifetime file lock prevents two cores from opening the same state. The VPN
owner serves a chmod-0600 Unix LocalAPI in app-private storage; a separate UI
process proxies to it. If UI and extension share a native runtime, the same
singleton remains authoritative. No process-sharing assumption is required.

Go duplicates the borrowed FD with CLOEXEC, verifies read-write flags, and uses
nonblocking read/write with bounded poll waits. It does not depend on fstat,
which the phone sandbox denies. Close joins pending I/O before releasing that
duplicate. ArkTS closes its original exactly once. The platform router never
invokes Linux netlink/iptables; an assigned-address change requires reconnection.
Atomic request-ID snapshots and stop commands bridge the extension lifecycle.
Timeouts do not authorize a second SDK operation while late cleanup is pending.

## Evidence and limits

Host regressions include two real upstream engines with real localhost UDP,
WireGuard handshakes/encryption and the production FD adapter. TCP and UDP IPv4
packets are preserved in both directions. These are packet tests, not a test of
phone application TCP sessions. Additional tests exercise real backend startup,
the actual private LocalAPI, ownership, error cleanup, callback SDK adaptation,
UI ON/OFF/logout and unresolved SDK calls. Target ARM64, ArkTS and packaged HAP
checks are separate; see the build's `dist/vpn-3.2.0-check.log`.

Final `make check` on 2026-10-10: **185 passing cases**, zero failed/skipped:
81 Go leaf cases, 5 ctypes, 9 real NAPI, 13 mock NAPI and 77 UI/VPN cases. Race,
vet, module verification and ARM64/ArkTS/HAP checks passed. Signing subsequently
verified the HAP, all three packaged native-library code signatures and the
permission signature. Signed versionCode: `3002000`; size: `27641124` bytes.
SHA-256:

```text
ea0838622730f9a93c32f89049370fc3379a45240f722be342e221301a877f76
```

The old fixed 3.1.4 signed package is preserved as
`tailscale-probe-3.1.4-signed.hap`. No dependency, upstream module or host
configuration was changed. Signing used the previously authorized credential
transiently; no credential was written to Git or the project.

The prior 3.1.4 phone probe proved acquisition, FD access flags, protection API
completion and cleanup. It did **not** prove packet I/O. The new socket, file
lock, raw packet format, physical-network exclusion, actual TCP/UDP traffic,
DERP, screen-off and network transitions remain phone acceptance items.

The fixed signed download name is `dist/hap/tailscale-probe-signed.hap`; inspect
its module version before installation. Signing uses the existing device-bound
debug profile outside Git, not a general public distribution certificate.

## Focused phone acceptance

Cover-install without uninstalling to retain the login state:

```sh
hdc install -r tailscale-probe-signed.hap
hdc shell aa start -a EntryAbility -b com.ezoo.tailscaleprobe
```

1. Confirm version **3.2.0 Alpha**, restored account and all visible online peers.
2. Turn ON, allow system VPN authorization, and wait for **已开启**. A successful
   old capability check is not this test. Record any failed stage verbatim.
3. In another phone app, connect by the peer's literal `100.x` address. For an
   existing desktop HTTP server, open `http://100.x.y.z:PORT` in the phone's
   browser. Check the VPN TX and RX counters increase. A peer must actually
   listen on the selected port, and ACL/firewall policy must permit the flow.
4. Verify UDP using an existing UDP echo/service and a phone UDP client; test
   reverse peer-to-phone traffic against a real listening phone app when the
   applicable ACL permits it. Ping alone is not sufficient TCP/UDP evidence.
5. Check a normal public website and DNS while ON, then OFF. OFF must confirm
   teardown, retain login/peers, stop Tailnet flows, and preserve ordinary access.
6. Repeat ON/OFF, screen-off/background, reopen the UI, Wi-Fi/cellular change,
   temporary loss/recovery and system revocation. Check no duplicate Tailnet
   identity and no stuck switch. Repeat a peer flow over DERP as well as direct.

On failure use **设置 → 诊断与日志 → 查询核心状态**. The result includes independent
VPN state, packet counters and the owner's sanitized recent logs, including
across processes. HiLog tags include `TailscaleNAPI` and `TailscaleVPN`.

MagicDNS, IPv6, exit nodes, subnet routes and always-on are not supported here.
Use IP literals. The fixed CGNAT route can conflict with a carrier/LAN service
or resolver using that range; include ordinary-network checks on the actual
network. Route exclusion/dynamic host-route refinement is not yet implemented.
