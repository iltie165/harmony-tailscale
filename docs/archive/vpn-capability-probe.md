# VPN capability probe — 3.1.4

Phone confirmation received 2026-10-10: `ok:true`, `stage:complete`, acquisition,
read-write access flags, process protection and all close/destroy checks passed.
Metadata remained EACCES-restricted, with packet I/O explicitly unverified.
The fixed artifact has since advanced to the [3.2.0 VPN Alpha](../vpn-alpha.md).
The historical probe package is retained separately; this diagnostic remains
capability-only and is blocked while a real VPN session is active.

This is the first platform milestone towards the confirmed functional VPN Alpha.
It is **not a VPN Alpha release** and does not provide Tailnet packet forwarding.

## What is implemented

- A non-exported `VpnProbeAbility`, separate from normal core startup/login.
- An explicitly requested diagnostic with a warning that system authorization
  can replace another active VPN. It never starts automatically.
- Temporary vNIC address `192.0.2.1/32`, an empty route list, MTU 1280, no DNS
  overrides and no IPv6 claim. The address is for this diagnostic only.
- `protectProcessNet()` (SDK API 22, compatible with target minimum API 24).
- Native descriptor inspection on an async NAPI worker: duplicate the borrowed
  FD, inspect validity/access flags/type, close only that duplicate. No Go C ABI
  change, packet payload capture, original FD mutation or forwarding.
- Close the acquired original FD, then destroy the owned platform connection.
  A rejected create does not destroy an unrelated connection. Failures stay
  failures even if later cleanup succeeds.
- Extension lifecycle cancellation checks after asynchronous acquisition and
  inspection, avoiding an eager close while the worker may still borrow the FD.
- Atomic private-file reports with a request identifier across the UI/extension
  process boundary. The UI ignores stale reports, bounds its polling, attempts
  to stop its started extension and suppresses updates after unmount.
- The report always contains `mode: capability-only` and
  `tunnelConnected: false`; login/device UI is not converted into connected VPN UI.

## 3.1.4: sandbox metadata access is not FD validity

The real 3.1.3 screenshot identifies the exact failed check: duplication and
F_GETFL succeeded, flags=133122, accessMode=read-write, flagsErrno=0;
fstat failed with statErrno=13 (EACCES), fileType unknown. Acquisition, process
protection, original/duplicate close and connection destruction all completed.
The previous inspector incorrectly required metadata access to establish FD
validity and read/write access mode.

FD validity now uses successful duplication/F_GETFL. Only metadata EACCES/EPERM
is tolerated for this SDK-acquired capability descriptor; the limitation remains
visible in `warning`, `metadataAvailable:false`, `fileType:unknown`, and errno.
Other stat errors, read-only/write-only FDs, known regular files and failed
duplicate cleanup still fail. No access flags are changed, no permissions are
requested or elevated, and no packets are read/written.

The UI labels this outcome **basic interfaces passed, metadata access restricted**,
not a verified packet device or working VPN. Both native and model reports
retain `packetIOVerified:false` and `tunnelConnected:false`.
Host regression link-wraps only the inspector's fstat boundary to inject
EACCES/EPERM/EBADF/EIO while running production native code. The wrapper is not
part of the target build; packaged binary checks reject its environment marker.
These tests prove policy/ownership behavior, not mobile packet transport.

Server verification on 2026-10-10: `make check` passed 149 cases (70 Go leaf,
5 C ABI, 8 real NAPI, 12 fault-mock NAPI, 54 UI/VPN), with no failures/skips.
ARM64/ArkTS/HAP and test-hook exclusion checks passed. Existing credentials
were reused ephemerally for signing; HAP, all native-library code signatures
and permission signature verified. Fixed download is
`dist/hap/tailscale-probe-signed.hap`, version 3.1.4, SHA-256
`b8c7879c8bb7088dff1243d91c7ba5eddf00209e2c532dff4ad0f0e4f00e04ec`.
The old signed 3.1.3 package is preserved. Device confirmation of the revised
basic-capability report and actual packet I/O still remain separate gates.

## 3.1.3: preserve native descriptor failure evidence

The user supplied a real 3.1.2 phone screenshot: `created`, `processProtected`,
`descriptorClosed` and `destroyed` are true; `ok` is false, with
`inspectDescriptor: Descriptor is not a readable/writable VPN candidate`.
This proves acquisition/protection/cleanup API completion, not packet transport.
The failure could be F_GETFL/fstat, access mode, or regular-file classification.
The old model discarded successful measurements whenever `ok` was false, so
its two false descriptor fields cannot distinguish these possibilities.

3.1.3 preserves the raw native JSON as `descriptorInspection`, and copies valid
boolean measurements even when candidate validation fails. Native inspection
now reports flags, access mode, file mode/type, per-operation errno, the failed
check stage and duplicate-close outcome. It retains the original candidate
policy; regular files are not silently accepted and flags are not mutated.
It still does not read/write packets, and does not claim that the platform
descriptor issue is repaired until the actual device result is available.

Server verification on 2026-10-10: `make check` passed 145 cases (70 Go leaf,
5 C ABI, 7 real NAPI, 11 fault-mock NAPI, 52 UI/VPN), zero failures/skips;
ARM64/ArkTS/HAP payload checks passed. Existing signing materials and the
previous user-supplied password were used in ephemeral process environment;
HAP, native code and permission signatures verified. Delivery filename remains
`dist/hap/tailscale-probe-signed.hap`, version 3.1.3, SHA-256
`da7dd5c9a0a7d083e89cc6a3108c49e2d726db782a2f48446a27be12f3bd5f86`.
The previous signed 3.1.2 package is preserved separately.

## 3.1.2: stalled authorization/start/cleanup diagnosis

The user allowed the system VPN dialog on 3.1.1, but the UI remained waiting.
The code inspection found that the old 60-attempt loop ran only after
`startVpnExtensionAbility` returned; both start and stop could wait indefinitely.
The supplied device log contained only TailscaleNAPI network-probe/receive-loop
warnings, not extension startup evidence. The exact device stall is not yet
identified, and this change does not claim to fix authorization or TUN transport.

- Start/authorization is bounded to 60 seconds; report waiting to 30 seconds;
  stop to 10 seconds. Cancellation is checked while an SDK Promise is pending.
- UI distinguishes startup, missing extension report, create, process protection,
  descriptor inspection and cleanup. The extension persists partial reports
  before each asynchronous platform operation. Errors preserve the last report.
- An unresolved SDK operation keeps a process-local lease. New probes are
  rejected until it settles, preventing late cleanup from stopping a newer
  probe. A late successful start gets exactly one cleanup attempt. Timeouts do
  not imply that the OS operation has been cancelled or cleanup succeeded.
- `device-test.sh` now includes the extension's `VpnCapabilityProbe` tag;
  a TailscaleNAPI-only tail cannot diagnose extension loading/authorization.
- Offline regressions cover genuinely unresolved start/stop/report Promises,
  late resolution/rejection, unmount, stage snapshots and persistence failure
  without sleeping for real time. Real device acceptance remains required.

Verification of 3.1.2 on 2026-10-10: `make check` passed 141 cases (70 Go leaf,
5 C ABI, 6 real-NAPI, 10 fault-mock NAPI, 50 UI/VPN), with no failures/skips.
ARM64, ArkTS/API metadata and HAP native payload checks passed. The package was
signed using existing materials and the previously user-supplied password in
ephemeral process environment; HAP/permission/all-native-library code-sign
verification passed. Delivery is `dist/hap/tailscale-probe-signed.hap`, version
3.1.2, SHA-256
`052cb8d1d5b3abd5544259459a805f7078b525d2433010b57805eab546964a9c`.
The old signed 3.1.1 package is retained as a backup. This server verification
does not prove that the phone now completes its extension lifecycle.

## What success does not prove

`readWriteDescriptor` records access flags, not an actual successful packet
read/write. `processProtected` means the API completed, not observed control/
DERP traffic exclusion. Actual TUN packet transport, physical-network routing,
Tailnet reachability, direct/DERP behavior, network-change handling and sustained
background service behavior remain future acceptance gates.

## Server and target-build evidence

The final `make check` completed successfully on 2026-10-10 using existing
offline images/caches; no packages, signing configuration or base environment
were changed. Source hygiene, Go race/vet/module/coverage gates also passed.

| Lane | Passed | Failed/skipped |
| --- | ---: | ---: |
| Existing Go leaf cases | 70 | 0 |
| Actual Linux C ABI (ctypes) | 5 | 0 |
| Actual production NAPI + real Go core | 6 | 0 |
| Actual production NAPI + fault-mock core | 10 | 0 |
| Production UI methods and VPN models/adapters with mocked platform APIs | 42 | 0 |
| **Total** | **133** | **0** |

The 20 additional cases cover two native integration variants, 15 probe-model/
extension/client cases and three UI integrations. They exercise authorization
denial, invalid FD, protection/inspection/close/destroy failure, concurrent calls,
cancellation at acquisition/worker boundaries, report validation, stale request
isolation, bounded polling and UI unmount. Host FD tests use `/dev/null` and a
regular file; neither is misrepresented as a real HarmonyOS TUN.

- ARM64 Go/native linking and full ArkTS/Hvigor compilation: passed.
- Packaged VPN extension declaration, native exports/links, API 24 minimum/API
  26 target, ELF/TLS and host-artifact exclusion: passed.
- Log: `dist/vpn-final-check.log`; other existing evidence: `dist/tests`.
- Unsigned HAP: `dist/hap/tailscale-vpn-capability-3.1.1-unsigned.hap`.
- SHA-256: `6146ab59e4b04b4e40a9f1f513467818f0f79305f5bd618e0cca9d8bbffec866`.
- `hdc list targets` on this server returned `[Empty]`.
- The original verification above concerns 3.1.1. That package was subsequently
  signed/verified using the user's previously supplied password and delivered
  as `dist/hap/tailscale-probe-signed.hap`; no new password file was created.
The fixed download filename is retained for subsequent verified builds.

## Focused device acceptance

1. Sign the current unsigned file using the existing device-valid profile and
   a transient keystore password. Verify the signature; do not install an
   unsigned file or accidentally reuse the old generic signed 3.0.6 package.
   See `scripts/sign-hap.sh` and `device-test.md` for signing inputs.
2. On the phone-connected machine, cover-install the new signed HAP to retain
   the existing app-private login state. Launch `com.ezoo.tailscaleprobe`.
3. Confirm existing login and peer-list behavior is intact and the main VPN
   switch remains disabled.
4. Open **设置 → 诊断与日志 → 验证系统 VPN 能力（不连接 Tailnet）**. Confirm
   the diagnostic and accept the system VPN authorization when appropriate.
5. Capture the real JSON/HiLog. A successful capability result must have
   `ok`, `created`, `descriptorValid`, `readWriteDescriptor`, `processProtected`,
   `descriptorClosed` and `destroyed` all true, `stage` complete and
   `tunnelConnected` false. There are no fabricated device results in this report.
6. Verify the temporary VPN is stopped, normal networking remains usable and
   login/device state is retained. Repeat the probe to detect stale results or
   lingering connections.
7. Exercise denial/revocation and preserve the exact error plus cleanup evidence.
   A timeout means authorization/runtime/cleanup remains unverified, not success.

For a stall, capture the last visible stage/report and both-process logs:

```bash
hdc shell hilog > vpn-probe-hilog.txt
```

Start capture before reproducing, press Ctrl-C after the error appears, and
preserve `VpnCapabilityProbe`, `TailscaleProbe`, ability-load exceptions and VPN
service entries. A `startVpnExtensionAbility` timeout is different from no
report after startup or a stalled `create`/`protectProcessNet`/`cleanup` stage.

Only after this platform evidence should the Tailscale packet adapter be claimed
usable. The next milestone is genuine other-app TCP/UDP access to one Tailnet
peer, then direct/DERP and mobile lifecycle acceptance.
