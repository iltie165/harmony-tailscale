# 3.3.5 — Local bootstrap retry and supplied dark icon

## Local service recovery

A recent service-ready snapshot can outlive its process; SDK extension-start
acknowledgement also precedes the Unix LocalAPI listener. Bootstrap retries a
refused local connection within its existing bounded window, preserving the
last error for diagnosis. It does not restart the owner repeatedly, log out or
clear saved credentials. An error-state remote UI proxy is disposed under the
operation lock before reconnecting, so a transient first failure does not
poison subsequent attempts. A confirmed new-owner startup failure still fails
explicitly. Diagnostic service start releases the failed startup overlay.

The phone screenshot proves a refused local socket, not the precise reason
the extension was unavailable. These fixes address evidenced startup/proxy
failure paths; persistent process exit still requires real phone Go/HiLog logs.

## Icon and delivery

The latest user-supplied dark PNG is copied unchanged into AppScope and entry
media as app_icon_dark.png. Application, launcher and start-window references
use that resource. The resource compiler can scale the packaged image; signed
and unsigned icon bytes must match. The intermediate compressed JPEG assets
are preserved only under dist/icon-backups, outside packaged resources.

The earlier 3.3.5 build succeeded but the separate signing step had not
completed; the fixed signed download still contained 3.3.4. Release signs and
verifies a versioned 3.3.5 artifact before replacing that fixed download, and
preserves the previous signed version.

## Verification

Complete make check passed 294 leaf cases, zero failures/skips: 106 Go,
6 ctypes, 10 real host NAPI, 14 mock NAPI and 158 UI/service/VPN tests. Added
regressions exercise actual Unix socket refusal followed by listener readiness,
old-ready snapshots, bounded permanent refusal, owner startup failure and
diagnostic overlay recovery. ARM64/ArkTS/HAP checks passed. Rebuilding the HAP
after replacing the compressed icon with the original PNG re-runs target and
payload verification; signing separately verifies signatures and permissions.

Evidence: dist/ui-3.3.5-check.log, dist/ui-3.3.5-icon-build.log and
dist/ui-3.3.5-sign.log. No Go/Tailscale/dependency/image/signing-config changes.

## Phone acceptance (pending)

Close VPN in the app and cover-install without uninstalling. Check the dark
launcher/start-window icon, cold startup, diagnostic startup retry, ON/OFF and
Moonlight regression. If socket refusal persists, collect the service-start
result and Go/HiLog logs; host tests and package/signature checks do not prove
that the phone keeps the extension alive or that traffic works on the device.
