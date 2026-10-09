# HarmonyOS device deployment and runtime validation

## Current status

The project produces a signed, statically verified HAP at
`dist/hap/tailscale-probe-signed.hap`. `hap-sign-tool verify-app` reports
`Verify success`, including successful code-sign verification for all three
packaged native libraries. At the time of this report, `hdc list targets`
returned `[Empty]`; consequently no real-device load/start logs exist yet.

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

1. **Query native versions** — must report ABI 2, Tailscale 1.86.2, the Go
   version, and `coreProbe: true`.
2. **Run platform diagnostics** — records storage, TCP, UDP, DNS, interfaces,
   polling network monitor, and default-route results.
3. **Start tsnet asynchronously** — must leave ArkUI responsive and return
   either `state: started` or a concrete Go error/panic.
4. **Read Go logs** — displays the same Go/Tailscale log buffer forwarded to
   HiLog.
5. **Close tsnet** — clean shutdown after the evidence has been captured.

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

Expected diagnostic behavior is not hard-coded as success. In particular,
Tailscale v1.86.2 currently has no OpenHarmony-specific default-route reader,
so the real device may report `defaultRoute.error: "TODO"`; this must be
recorded as a compatibility issue while the remaining checks are evaluated
independently.
