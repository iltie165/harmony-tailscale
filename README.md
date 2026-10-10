# harmony-tailscale

HarmonyOS ARM64 C ABI wrapper and Stage-model client shell for the official
Tailscale Go core.

This is an unofficial community project, not an official Tailscale or Huawei client.

## Engineering and tests

```bash
make test    # offline unit/Mock/race + real host C ABI/NAPI + UI contracts
make check   # all tests plus actual ARM64/ArkTS/HAP build
```

No phone, Tailscale account, signing password or new packages are needed.
See [contribution rules](CONTRIBUTING.md), [architecture](docs/architecture.md)
and [test boundaries](docs/testing.md). CI configuration is checked in for a
pre-provisioned HarmonyOS self-hosted runner; it has not been deployed here.

## Pinned inputs

- Tailscale module: `tailscale.com v1.86.2`
- Tailscale tag commit: `d72494bac7a2fb6b6a01715cfc5bcc903dbd7594`
- Required Go version: `1.24.4` (the build image currently provides `1.24.5`)
- Build image: `harmonyos-go:1.24`
- Target: `GOOS=openharmony GOARCH=arm64 CGO_ENABLED=1`

## Build

Dependencies must already exist in `.cache/gomod`; the build keeps
`GOPROXY=off` and `-mod=readonly` so the pinned dependency graph cannot change.
All normal build/test/verification containers default to offline networking.
Use `HARMONY_GOMODCACHE` to point to an alternate pre-hydrated absolute module
cache. Hydration remains a separate explicitly authorized step; builds do not
install dependencies.

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

### Client UI and 3.1.1 VPN capability probe

The Chinese-language client UI separates the welcome/login screen from the
signed-in device list. It displays the real account, Tailnet, local Tailscale
IPs and visible online peers, with OS icons, name/tag/user filters and device
details. Returning from browser authentication refreshes the session automatically.
Existing sessions are restored on launch; bounded polling handles asynchronous
backend startup. Settings contains diagnostics and selectable raw results.

The VPN switch is deliberately disabled and labelled **尚未接入**: userspace
`tsnet` authentication is not full-device VPN connectivity. Version 3.1.1 adds
an opt-in diagnostic VPN extension: create a temporary vNIC with no routes or
DNS overrides, inspect its descriptor, request physical-network process
protection, and close/destroy it. It does not forward any Tailnet packets.
The diagnostic is under **设置 → 诊断与日志 → 验证系统 VPN 能力**.
See [probe acceptance and verification](docs/vpn-capability-probe.md).

Run production UI method/response-contract tests with mocked native APIs:

```bash
./scripts/test-ui.sh
```

Tests run offline using the existing Node/TypeScript compiler in
`harmonyos-dev:24.04`; no dependency installation is needed. They cover session
restore, browser dispatch, foreground refresh, bounded polling, backend errors,
stale-device clearing, logout and navigation. They do **not** render ArkUI or
replace device layout/browser/network acceptance. Hvigor separately compiles
the complete ArkUI builders.

The current diagnostic artifact is `dist/hap/tailscale-vpn-capability-3.1.1-unsigned.hap`. Signing requires
the transient P12 password, which has intentionally not been saved. The generic
signed HAP may still be **3.0.6**, not 3.1.0.

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
instead of polling a status snapshot. Diagnostics test the control `/key?v=123` HTTPS endpoint through the netns
dialer family so transport failures are reported separately from browser launch
failures and do not repeat the old unrelated default-HTTP probe.

Online peers can be listed without a filter, filtered by ACL tag such as
`tag:server`, by login/display name with `user:name`, or by hostname text. ACL
policy groups (`group:example`) are not exposed by the node LocalAPI and require
a separate management backend using Tailscale OAuth; an OAuth client secret
must never be embedded in the HAP.

Build the Go library and unsigned debug HAP offline using existing caches:

```bash
./scripts/build-hap.sh
```

The first dependency hydration may require an explicitly authorized networked
step. Routine builds do not access that network. Output:

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
