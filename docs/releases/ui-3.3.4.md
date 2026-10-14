# 3.3.4 — Supplied icon and local startup readiness

> 历史内部测试包记录：本文 2.x/3.x 编号不是正式发行版本。当前版本见
> [版本规范](../versioning.md)，旧包证据保留原样。

## Icon

The supplied square PNG is copied unchanged to AppScope and entry media
resources as `app_icon_blue.png`. Application icon, desktop EntryAbility icon
and start-window icon reference that asset. The SDK resource compiler scales
the packaged icon to 512x512 RGBA; original source artwork remains unchanged.
The previous unused SVG is retained. Phone launcher masking/cache appearance
has not been device-verified.

## Separate three kinds of readiness

The startup overlay now covers local service initialization only. A confirmed
current service/core releases it immediately; live account and peer reads
continue without a global busy lock. The 30-second failure view applies to
local bootstrap, not to waiting for remote authentication or DERP. A 5-second
bounded account read reports its failure locally without reopening the overlay.
Manual VPN commands do not wait for an unrelated account refresh task.

For the pinned upstream, Starting can persist after an authorized netmap is
received until the engine has a live peer or DERP. Requiring Running before
TUN attachment creates an unnecessary dependency. Native readiness therefore
requires a living engine, Starting/Running state, non-logged-out WantRunning
prefs, an authorized nonexpired current node/netmap/key, assigned Tailnet IPv4
and the same address already applied by the engine router. A saved UI account,
cached peer list or nonzero online-device count cannot provide that proof.

`networkMapReady`/`assignedIPv4` in the owner's independent native snapshot
carry this current configuration proof. The client checks core generation and
the actor uses it to acquire/protect/attach a TUN without waiting for a slow
account query. Attach rechecks native readiness and address. With a current map,
Starting is allowed for official LocalAPI peer reads; an empty authorized
Tailnet is equally valid. Known auth denial/expiry still prevents readiness,
and SDK resource, cancellation, intent revision and OFF guarantees remain.

VPN connected continues to require native attachment plus the service's real
SDK interface/protection/cleanup facts and OS interface confirmation. It means
the local VPN is established, not that every peer or relay is currently
reachable. The upstream warm-up warning is translated to a precise path-setup
message when the network config is ready, not hidden; other health warnings and
raw diagnostic status are preserved.

## Verification and acceptance

Complete make check passed: 289 leaf cases, zero failures/skips (105 Go,
6 ctypes, 10 real NAPI, 14 mock NAPI, 154 UI/platform/VPN), ARM64/ArkTS/HAP.
An actual pinned upstream backend with a real local encrypted control server,
no peer and no DERP remains Starting while it reports an authorized map,
reads an empty peer list and attaches/detaches the TUN. This is configuration
and lifecycle proof, not traffic delivery without a reachable transport.
Negative map tests cover missing/unapproved/expired/addressless nodes and keys.
Actor/UI tests cover a pending account read without a global mask, local
bootstrap timeout, real-map ON, preserved health warnings and current IP.

Evidence: dist/ui-3.3.4-check.log and dist/ui-3.3.4-sign.log. No dependency,
Go/Tailscale version, image, signing-config or permission change. Prior signed
3.3.3 is preserved; fixed download uses 3.3.4/3003004.

Phone acceptance remains pending. Close VPN in the app and cover-install
without uninstalling. Verify desktop/start-window icon, fast local startup,
slow/offline control connection without a 30-second full-page mask, real device
sync, ON while a current map is available, auth denial/expiry, OFF/recovery and
Moonlight traffic. Config readiness and online peer metadata do not replace
actual peer-path/DERP/packet checks.
