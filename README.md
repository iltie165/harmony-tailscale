# harmony-tailscale

HarmonyOS ARM64 C ABI wrapper and Stage-model client shell for the official
Tailscale Go core.

## Pinned inputs

- Tailscale module: `tailscale.com v1.86.2`
- Tailscale tag commit: `d72494bac7a2fb6b6a01715cfc5bcc903dbd7594`
- Required Go version: `1.24.4` (the build image currently provides `1.24.5`)
- Build image: `harmonyos-go:1.24`
- Target: `GOOS=openharmony GOARCH=arm64 CGO_ENABLED=1`

## Build

Dependencies must already exist in `.cache/gomod`; the build keeps
`GOPROXY=off` and `-mod=readonly` so the pinned dependency graph cannot change.
Build and verification containers use host networking and receive the proxy
from `HARMONY_PROXY_URL` / `HARMONY_ALL_PROXY_URL` (defaulting to the host proxy
on port 7890), as required by the initial HAP build workflow.

```bash
./scripts/build.sh
```

Successful output is written to:

- `dist/libtailscale_ohos.so`
- `dist/libtailscale_ohos.h`

The build script automatically checks the ELF architecture, exported C ABI,
dynamic dependencies, Go module metadata, TLS relocations, retention of the
`tsnet.Server.Start` core entry point, and a Native C++ cross-link smoke test.

Compilation success does not imply successful loading or operation on a real
HarmonyOS device.

## Stage HAP runtime probe

The `entry` module implements this call chain:

```text
ArkTS UI -> NAPI async work -> Go C ABI -> tsnet.Server
```

It provides native version/core checks, asynchronous `tsnet.Server.Start`,
official interactive Tailscale login, control-plane status/logout, online peer
listing, platform diagnostics, lifecycle close, and a bounded Go log buffer.
The state directory is always the app's private `filesDir/tailscale`, and the
hostname is supplied by the UI. No auth key or management credential is
embedded in the project. Short-lived login URLs are returned only to ArkTS for
opening in the system browser and are redacted from Go/HiLog output.

Interactive login listens for the official IPN Bus `BrowseToURL` notification
instead of polling a status snapshot. Diagnostics also test HTTPS reachability
to `controlplane.tailscale.com` so certificate or network failures are reported
separately from browser-launch failures.

Online peers can be listed without a filter, filtered by ACL tag such as
`tag:server`, by login/display name with `user:name`, or by hostname text. ACL
policy groups (`group:example`) are not exposed by the node LocalAPI and require
a separate management backend using Tailscale OAuth; an OAuth client secret
must never be embedded in the HAP.

Build the Go library and unsigned debug HAP with the host proxy forwarded into
the container:

```bash
./scripts/build-hap.sh
```

Defaults can be overridden with `HARMONY_PROXY_URL` and
`HARMONY_ALL_PROXY_URL`. Output:

```text
dist/hap/tailscale-probe-unsigned.hap
```

The HAP build verifies that both native libraries are packaged as AArch64,
that the NAPI library depends on `libtailscale_ohos.so`, that the Go start
symbol is exported, and that no `R_AARCH64_TLS_TPREL64` relocation is present.

Sign the generated HAP with the device-valid profile under
`/home/zackli/harmony-signing` without storing passwords in the repository:

```bash
export HARMONY_KEYSTORE_PASSWORD='...'
# Set HARMONY_KEY_PASSWORD only when it differs from the keystore password.
./scripts/sign-hap.sh
unset HARMONY_KEYSTORE_PASSWORD HARMONY_KEY_PASSWORD
```

The result is `dist/hap/tailscale-probe-signed.hap`. See
[`docs/device-test.md`](docs/device-test.md) for deployment and log capture.
