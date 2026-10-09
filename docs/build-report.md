# Build report

## Scope

Phase 1 compiles the official Tailscale Go core as a HarmonyOS ARM64 C shared
library. It does not provide ArkTS UI, VPN Extension integration, login, or a
working network connection.

## Source pin

- Module: `tailscale.com v1.86.2`
- Upstream commit: `d72494bac7a2fb6b6a01715cfc5bcc903dbd7594`
- Upstream release time: `2025-07-29T16:56:20Z`
- Upstream `go.mod`: `go 1.24.4`

## Build status

Passed using the unmodified official Go module.

- Build mode: `c-shared`
- Output architecture: ELF64 AArch64
- Exported C ABI: version, ABI version, Go version, core probe, string free
- Tailscale core proof: module metadata contains `tailscale.com v1.86.2` and
  the binary retains `tailscale.com/tsnet.(*Server).Start`
- Dynamic dependency: `libc.so`
- TLS: `R_AARCH64_TLSDESC` present; `R_AARCH64_TLS_TPREL64` absent
- Native C++: HarmonyOS ARM64 smoke library compiles and links against the
  generated header and shared library

Verified artifacts:

| File | Size | SHA-256 |
| --- | ---: | --- |
| `dist/libtailscale_ohos.so` | 25,515,456 bytes | `2118a7b3d2bb1d0017af6d44ecde61f0663296c0692f098bff49996903056b52` |
| `dist/libtailscale_ohos.h` | 1,958 bytes | `e25d3dc1959ce2e705b904509f508af2e109a7026d59a1125b893bbf67062ae2` |

## Compatibility patches

None. No upstream Tailscale source files were changed.

## Device status

Not tested. A successful build must not be interpreted as proof that the
library loads or that networking works on a HarmonyOS device.

In particular, real-device validation still needs to cover the HarmonyOS
dynamic loader, application sandbox storage, socket behavior, network change
monitoring, DNS integration, background execution, and VPN Extension wiring.

## Next phase

1. Package the shared library and generated header into a minimal Native C++
   HarmonyOS module.
2. Load the library on an ARM64 device and call only the version and core probe
   functions first.
3. Add lifecycle and status C ABI functions around `tsnet.Server` without
   exposing Go pointers across the ABI.
4. Integrate platform-owned networking and VPN Extension plumbing before
   attempting login or persistent tailnet connectivity.
