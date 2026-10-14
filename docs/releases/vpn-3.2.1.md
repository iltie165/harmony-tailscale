# VPN 3.2.1 — ICMP and UI fixes

> 历史内部测试包记录：本文 2.x/3.x 编号不是正式发行版本。当前版本见
> [版本规范](../versioning.md)，旧包证据保留原样。

2026-10-12. The user confirmed 3.2.0 can stream the home PC with Moonlight
from another phone app while VPN is ON. This is real application traffic
evidence, not just a capability probe. They also reported that PC-to-phone
ping failed, periodic UI updates jumped, and system bars left white strips.

## Changes

- Local IPv4 ICMP echo replies are generated using upstream packet/TUN APIs.
  The callback runs **after** the official inbound ACL/shields-up filter and
  handles only the node's assigned IPv4, preserving ID, sequence and payload.
  Consumed requests are not sent to the OS, avoiding duplicate responses.
  No fake-mode responder, raw ICMP socket, permissive production ACL, or
  upstream-source change is used. TCP/UDP continue into the system interface.
- Foreground and timer refreshes are silent: no global busy flag, loading
  notice, disabled controls or erasure of the user's current diagnostic output.
  Equal status/peers retain identity; changing log buffers alone do not update
  the VPN card. Changed peer rows are individually keyed by their contents so
  ArkUI does not retain stale text. Details follow the matching peer update.
  Manual refresh remains explicit and backend failures remain visible.
- Native refreshes are single-flight. Login/logout, diagnostics and VPN
  handoffs wait for an in-flight refresh before changing core ownership.
- Full-window gradient and system-bar colors replace the white strips.
  Controls/scrolling stay inside status/navigation/cutout safe areas, using
  pixel-to-vp conversion and an avoid-area subscription for rotation.
  Stage destruction removes the subscription; failed full-screen setup resets
  extra content insets. System bars are retained with dark content colors.

## Verification

`make check` completed: **195 passing leaf cases**, zero failures/skips:
83 Go, 5 ctypes, 9 real host NAPI, 13 mock NAPI and 85 UI/VPN cases.
Offline module verification, race/vet, domain coverage and real HarmonyOS
ARM64/ArkTS/HAP checks passed. Evidence: `dist/vpn-3.2.1-check.log`.

Two real upstream engines over localhost encrypted WireGuard transport reply
to ICMP in both directions without an OS responder. Independent checksum,
payload preservation, single-response, no-OS-delivery and inbound-denial checks
passed; existing TCP/UDP bidirectional tests still pass. Poll test helpers now
retry Go preemption EINTR without extending deadlines. These are host packet
tests, **not** new phone ping results or reverse phone application sessions.

Runtime tests execute actual UI/window methods with mock native/SDK ports:
unchanged model identity, visible-field updates, silent timer behavior,
refresh/handoff serialization, failure/unmount, converted insets, rotation,
subscription cleanup and interrupted startup. They do not render ArkUI on a
phone. Updated rendering and safe-area behavior need phone verification.

The existing device-bound signing materials and previously authorized password
were reused transiently. HAP, native code signatures and permission signatures
passed verification (`dist/vpn-3.2.1-sign.log`). No dependency was installed;
no credential was newly persisted. The fixed download was atomically replaced
after verification; the old package is `tailscale-probe-3.2.0-signed.hap`.

- Download: `dist/hap/tailscale-probe-signed.hap`
- Version: **3.2.1**, code **3002001**
- Size: **27666040** bytes
- SHA-256: `15e4ae7ae8552646f5444423b2eea2709e1548fe4571088d8f0ae29fadf61652`

## Phone acceptance

1. Turn VPN OFF before cover-installing (do not uninstall). Confirm **3.2.1**.
2. Turn ON, then run normal PC `ping <phone's 100.x address>`. Incoming policy
   must permit PC-to-phone traffic: an established phone-initiated Moonlight
   session does not alone prove the reverse ACL permits new requests.
3. Keep Moonlight running to check that ordinary TCP/UDP still work.
4. Leave the dashboard/detail/settings/diagnostics open for at least 20 seconds:
   counters/real changes update without a loading banner or scroll jump, input
   remains usable and manual diagnostic output is preserved. Try manual refresh.
5. Check top/bottom painting, readable status/navigation items and controls clear
   of the bars/cutout; rotate the phone and check insets again.

If PC ping still times out, collect the current core status/logs and compare
ordinary ICMP with `tailscale ping <phone-IP>` (the latter defaults to a
different diagnostic protocol). Check reverse ACL before attributing all
failures to the phone. No Tailnet policy has been changed by this release.
