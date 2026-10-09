# HarmonyOS device deployment and runtime validation

## Current status

The project produces a signed, statically verified HAP at
`dist/hap/tailscale-probe-signed.hap`. Version 3.0.0 adds official interactive
login, control status/logout, and online peer listing. Phase 2 was proven on a
HarmonyOS 6.1.1/API 24 device; the new Phase 3 login functions still require a
fresh real-device run.

## Prerequisites

1. Enable Developer Mode and USB debugging on the HarmonyOS device.
2. Connect it to the Ubuntu host and authorize the host on the device.
3. Export the P12 password only for the signing command, then sign:

   ```bash
   export HARMONY_KEYSTORE_PASSWORD='...'
   # Only if the private-key password differs:
   # export HARMONY_KEY_PASSWORD='...'
   ./scripts/sign-hap.sh
   unset HARMONY_KEYSTORE_PASSWORD HARMONY_KEY_PASSWORD
   ```

   The script validates that the signed profile is for
   `com.ezoo.tailscaleprobe`, uses the complete certificate chain from
   `lch-phone.cer`, signs with `debug.p12`, verifies the result with
   `hap-sign-tool`, and writes `dist/hap/tailscale-probe-signed.hap`.

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
2. **Run platform diagnostics** — records storage, TCP, UDP, DNS, interfaces,
   polling network monitor, and default-route results.
3. **Start tsnet asynchronously** — must leave ArkUI responsive and return
   either `state: started` or a concrete Go error/panic.
4. **Login with official Tailscale** — opens the short-lived authentication URL
   in the system browser. Complete login and return to the app.
5. **Refresh control status** — must progress to `backendState: Running`, show
   at least one Tailscale IP, and identify the current tailnet.
6. **List online machines** — leave the filter blank for all visible online
   peers, use `tag:server` for an ACL tag, or `user:name` for a user identity.
   A `group:name` filter must return the explicit management-OAuth limitation.
7. **Read Go logs** — displays the same Go/Tailscale log buffer forwarded to
   HiLog.
8. **Logout from Tailscale** — verifies control-plane logout when explicitly
   intended; this clears the node login state.
9. **Close tsnet** — clean shutdown after the evidence has been captured.

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
