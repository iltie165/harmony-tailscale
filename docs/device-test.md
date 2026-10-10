# HarmonyOS device deployment and runtime validation

## Current status

Version 3.0.6 official login and online peers have been confirmed on the user's
real HarmonyOS phone. Version 3.1.0 implements the redesigned UI and has passed
host Mock tests, ArkTS compilation and HAP native-payload verification. Its
layout and automatic foreground refresh await device validation. The new package
is `dist/hap/tailscale-ui-3.1.0-unsigned.hap`; the previously signed generic HAP
remains 3.0.6 until a signing password is supplied again.

## Prerequisites

1. Enable Developer Mode and USB debugging on the HarmonyOS device.
2. Connect it to the Ubuntu host and authorize the host on the device.
3. Export the P12 password only for the signing command, then sign:

   ```bash
   read -rsp 'P12 password: ' HARMONY_KEYSTORE_PASSWORD
   echo
   export HARMONY_KEYSTORE_PASSWORD
   # Only if the private-key password differs:
   # export HARMONY_KEY_PASSWORD='...'
   ./scripts/sign-hap.sh dist/hap/tailscale-ui-3.1.0-unsigned.hap dist/hap/tailscale-ui-3.1.0-signed.hap
   unset HARMONY_KEYSTORE_PASSWORD HARMONY_KEY_PASSWORD
   ```

   The script validates that the signed profile is for
   `com.ezoo.tailscaleprobe`, uses the complete certificate chain from
   `lch-phone.cer`, signs with `debug.p12`, verifies the result with
   `hap-sign-tool`, and writes `dist/hap/tailscale-ui-3.1.0-signed.hap`.

The repository intentionally contains no certificate, private key, profile,
password, or auth key. Signing inputs remain outside the repository in
`/home/zackli/harmony-signing`.

## Confirm device visibility

```bash
docker run --rm --network host --privileged \
  -v /dev/bus/usb:/dev/bus/usb \
  harmonyos-dev:24.04 \
  /opt/harmony/command-line-tools/sdk/default/openharmony/toolchains/hdc list targets
```

Do not proceed while the output is `[Empty]`.

## Install, launch, and capture logs

### UI 3.1.0 acceptance

On the machine physically connected to the phone:

```bash
hdc install -r tailscale-ui-3.1.0-signed.hap
hdc shell aa start -a EntryAbility -b com.ezoo.tailscaleprobe
```

1. Cover-install without uninstalling to retain the existing login state.
2. A restored Running session shows account, Tailnet, local IP and online devices.
   A signed-out session shows the welcome/login screen.
3. Login opens the official browser flow. Return after authentication; the app
   should update automatically without another login click.
4. Try list refresh, a known `tag:`/`user:` filter, an unmatched query and `group:`.
   Backend errors must not be disguised as successful empty lists.
5. Open a device card; check selectable IP/DNS and optional user/tag fields.
6. Check narrow-screen scrolling, long names, system back and visible progress.
7. VPN **must remain disabled**, labelled **尚未接入**, even when authenticated.
8. **设置 → 诊断与日志** retains versions, status, diagnostics, logs and browser
   testing. Raw results remain selectable; authentication URLs are redacted.
9. Cancel logout confirmation once. Explicitly confirm only when ready to test
   re-authentication; logout failure must retain the account UI.

Capture welcome/home/settings screenshots for visual acceptance. Server Mock
tests and successful HAP compilation do not replace this step.

### Legacy 3.0.6 probe controls

```bash
cd /home/zackli/work/harmony-develop/harmony-tailscale
./scripts/device-test.sh dist/hap/tailscale-probe-signed.hap
```

In the application, press these buttons in order:

The hostname field can be left at its default `harmony-tsnet`. It accepts only
ASCII letters, digits, and hyphens (1-63 characters); no auth key is entered in
this phase. The app-private state directory is selected automatically.

1. **Query native versions** — must report ABI 3, Tailscale 1.86.2, the Go
   version, and `coreProbe: true`.
2. **Run platform diagnostics** — records storage, TCP, UDP, DNS, an HTTPS
   request to the official control plane, interfaces, polling network monitor,
   and default-route results.
3. **Start tsnet asynchronously** — must leave ArkUI responsive and return
   either `state: started` or a concrete Go error/panic.
4. **Test system browser only** — opens the public Tailscale login home page
   without invoking Go or tsnet. This isolates HarmonyOS link dispatch from
   control-plane authentication URL generation.
5. **Login with official Tailscale** — subscribes to the official IPN Bus
   `BrowseToURL` event, then opens the short-lived authentication URL in the
   system browser. If `openLink` fails, the app retries with an implicit
   `ACTION_VIEW_DATA` Want. Complete login and return to the app.
   On failure, the returned JSON embeds the newest 24 sanitized Go log lines in
   `debugLogs`; this evidence does not depend on HiLog delivery.
   Version 3.0.6 disables Tailscale's Linux `netns` socket binding on
   OpenHarmony, matching official userspace-networking mode. The Go logs must
   contain `platform adapter: Tailscale netns disabled` before login.
6. **Refresh control status** — must progress to `backendState: Running`, show
   at least one Tailscale IP, and identify the current tailnet.
7. **List online machines** — leave the filter blank for all visible online
   peers, use `tag:server` for an ACL tag, or `user:name` for a user identity.
   A `group:name` filter must return the explicit management-OAuth limitation.
8. **Read Go logs** — displays the complete Go/Tailscale log buffer in the UI;
   the NAPI bridge forwards only its newest 2.4 KB as one atomic HiLog record so
   HarmonyOS logging rate limits cannot discard later chunks containing the
   login failure.
9. **Logout from Tailscale** — verifies control-plane logout when explicitly
   intended; this clears the node login state.
10. **Close tsnet** — clean shutdown after the evidence has been captured.

Press `Ctrl-C` in the terminal after the results appear. The script saves the
filtered device output to:

```text
dist/device-logs/tailscale-probe-hilog.log
```

## Acceptance evidence

Acceptance A requires a real log line from tag `TailscaleNAPI` showing the
version JSON. Acceptance B requires the JSON returned by `tsnet.Start()` plus
the associated Go log lines. A HAP build, ELF inspection, emulator output, or
invented sample log is not a substitute.

Expected diagnostic behavior is not hard-coded as success. On the tested API
24 device, raw default-route Netlink access returned `bind: permission denied`,
and route-change subscription fell back to polling. Both limitations are
reported verbatim while storage, socket, DNS, interface, and engine results are
evaluated independently.
