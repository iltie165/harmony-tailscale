# 3.3.1 — VPN recovery loop Alpha

> 历史内部测试包记录：本文 2.x/3.x 编号不是正式发行版本。当前版本见
> [版本规范](../versioning.md)，旧包证据保留原样。

## Implemented behavior

The user-requested recovery loop is implemented without changing the pinned
upstream, SDK/image, module versions, signing configuration or app permissions.
It is not a system wake-lock, always-on system VPN or phone-residency guarantee.

- `VpnRecoverySupervisor` runs in the app runtime, not in page refresh timers.
  UIAbility creation binds it even before page creation; foreground/background
  and page disposal do not disable an accepted ON. Ability destruction stops
  its timer. If the entire runtime is killed or suspended, it cannot run.
- An atomic app-private `vpn-intent.json` stores only version, enabled and a
  revision. Missing/corrupt intent does not reconstruct ON from saved display
  data, old resource snapshots or extension commands. Upgrade from 3.3.0 starts
  without automatic ON until the user explicitly enables it once.
- While ON, a single-flight check runs approximately every second after the
  preceding check settles. It queries OS-visible networks and live owner/core
  identity. This is a scheduling interval, not a promised reconnection time.
- A healthy live core with its expected OS VPN interface is reused. Temporary
  control reconnect on an intact interface is left to the upstream core. OS
  interface loss requests serialized detach/destroy/create/protect/attach repair
  on the same authoritative core. No peer-list query blocks automatic recovery.
- A stopped/missing core/extension uses the existing generation-aware service
  bootstrap and saved official credentials. Its new TUN is enabled only by a
  current explicit ON intent and live official auth/Running/assigned-IP checks.
  Live-core/stale-heartbeat ambiguity is never grounds to forcibly close it.
- Transient failures retain ON and retry after 1, 2, 4, 8, 16 and then up to
  30 seconds. Physical-network absence waits without booting/creating a VPN;
  OS query failures are errors, not fictional interface presence. The existing
  SDK-operation lease prevents retries racing unresolved SDK calls.
- Auth expiry, known VPN creation/permission denial and a different OS-visible
  VPN suspend automatic attempts. The user handles the condition and explicitly
  cycles ON again. Recovery never destroys an unknown VPN to make room.
- OFF publishes cancellation immediately and persists the new OFF revision
  before waiting for unrelated peer refreshes. Logout also cancels recovery
  before refreshing/revoking credentials. New commands carry intent revision
  and owner generation; the actor rechecks stored intent after SDK awaits.
  Late old ON work cannot attach after OFF, logout or a revision change.
- OFF storage/cancel publication errors remain visible, but do not skip actual
  network disconnect. SDK/native cleanup uncertainty does not become a false
  disconnected success. Descriptor-close uncertainty does not permit new FD
  acquisition or replacement of an otherwise-live core.
- UI separates wanted ON from actual connected. Automatic recovery does not
  set global UI busy. Successful recovery additionally requires the expected
  OS VPN interface; a native connected flag alone is insufficient.
- Diagnostics include recovery phase, failed-check count, next retry deadline,
  first failed-check time and most recent recovery-after-failure duration,
  alongside core ID/start time and service/resource/stop-reason snapshots.
  Duration starts at the first observed failed check, not necessarily the
  kernel's actual interruption time; immediate successful repairs have no
  failed-check interval to report. This is not a Moonlight reachability probe.

## System boundary

The compatible API 24 VPN lifecycle exposes no reliable manual-stop versus
system-reclaim reason. With app intent ON, an unclassified extension/VPN stop
is treated as an interruption to restore. Use the **app's OFF switch** to cancel
recovery deliberately before disabling/replacing the VPN in system settings.
Known authorization denial or another visible VPN blocks attempts.

`getAllNets`/capability/link-address APIs already use the app's declared
GET_NETWORK_INFO permission. Expected VPN identification uses the stored current
Tailnet IPv4, together with live service generation/native ownership. It is not
a new OS bundle-owner API and cannot distinguish an unrelated interface with an
identical address. Interface visibility, netmanager registration timing, restart
permission and callbacks on Huawei phone firmware are still unverified.

No system-alive, background scheduling or automatic restart guarantee follows
from locking the app in recents. No synthetic onRestart callback, generic
phone service, additional background-task entitlement or forced-stop workaround
has been introduced. Device reproduction and measurement are deliberately the
next task, not claimed as completed here.

## Verification and delivery

Final `make check`: **275 passing leaf cases**, zero failures/skips:
102 Go, 6 ctypes, 9 real host NAPI, 13 mock NAPI, 145 UI/service/recovery cases.
The unchanged real upstream control/DERP/encrypted transport regressions still
pass. New recovery tests execute production ArkTS models on the host with
explicit platform/native substitutions; they are not phone kernel evidence.
ARM64, real ArkTS compilation, HAP payload checks and signature verification pass.

Regressions cover persistent ON/OFF, cold supervisor restoration, corrupt/missing
intent, backoff and blockers, single-flight/background/page-independent timers,
stopped-generation replacement, same-core interface repair, stale revisions,
OFF during late SDK bootstrap/create, storage faults, OFF before peer refresh,
logout after interface loss, control outage without teardown, network/foreign
VPN classification and native-connected without OS-interface confirmation.

Evidence: `dist/recovery-check.log`, `dist/tests/*`,
`dist/vpn-3.3.1-sign.log`. Delivery is `dist/hap/tailscale-probe-signed.hap`,
versionCode `3003001`, versionName `3.3.1`, 27,849,661 bytes, SHA-256:

```text
c6ca020dfd1eeaaa2287f92d2d6c8929f4634c724efbb2c1233cea6acadd830c
```

Previous signed 3.3.0 is preserved as
`dist/hap/tailscale-probe-3.3.0-signed.hap`. Existing signing credential was
retrieved from the same prior authorized record and used only in the signing
subprocess environment, without new password persistence. Close the old VPN
before cover-installing; do not uninstall/erase the saved account. The new
recovery intent is established when ON is explicitly enabled after upgrade.
