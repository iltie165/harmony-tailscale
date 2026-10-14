# Engineering verification — 2026-10-10 UTC

## Outcome

`make check` passed locally, offline, with no phone, public control-plane login,
new dependencies, signing credentials or base-environment changes.

| Runtime test lane | Passed | Failed/skipped |
| --- | ---: | ---: |
| Go unit, race and real LocalAPI stream (leaf cases; 28 top-level functions) | 70 | 0 |
| Loaded Linux C ABI (Python ctypes) | 5 | 0 |
| Production NAPI + real Go core on Node | 5 | 0 |
| Production NAPI + SDK/core fault injection | 9 | 0 |
| Production UI methods and Go-producer/ArkTS-consumer contracts | 24 | 0 |
| **Total non-duplicated cases** | **113** | **0** |

Go parent-suite pass events are not counted twice. `go vet`, `go mod verify`,
Go formatting/source hygiene and native host warnings-as-errors also passed.

## Measured business-domain statement coverage

| Domain | Covered/total | Observed | Gate minimum |
| --- | ---: | ---: | ---: |
| `login.go` | 55/57 | 96.49% | 90% |
| `operations.go` | 129/129 | 100.00% | 95% |
| `status.go` | 63/63 | 100.00% | 95% |
| `logging.go` | 30/31 | 96.77% | 90% |
| `runtime.go` | 9/9 | 100.00% | 95% |
| `types.go` | 4/4 | 100.00% | 100% |

Entire Go package: **87.08%**
(391/449 statements), including
C adapters and platform probe implementations. This is not upstream Tailscale,
ArkUI renderer or HarmonyOS device coverage.

## Target compile and package

- Pinned upstream: Tailscale v1.86.2, C ABI remains 3.
- OpenHarmony ARM64 Go shared build and native cross-link: passed.
- ELF64/AArch64/shared type, expected C symbols/header, pinned module and build
  metadata (`GOOS=openharmony`, `GOARCH=arm64`, CGO), and TLS checks: passed.
- Real HarmonyOS SDK/Hvigor compilation, including complete ArkTS builders: passed.
- Packaged NAPI basename-only dependency/no build-time RPATH, three AArch64
  native libraries (Go, NAPI, libc++), no host `.node`/Go host library: passed.
- Packaged `compileSdkType: HarmonyOS`, min API 24, target API 26: passed.
- Unsigned output: `dist/hap/tailscale-probe-unsigned.hap` (version 3.1.0).
- SHA-256: `bcf075021aed9a15421ef36cbabae3ed6cddbde757e18e24ccfcf53b26b00229`.
- No new signed release was produced or substituted for the last signed release.

Existing SDK warnings include the missing signingConfig and the SDK's
not-yet-verified native declaration warning; runtime NAPI exports are explicitly
checked by host tests. Neither warning is silently claimed as device evidence.

## Environment observed

Existing local image IDs (no pulls/installs; gate uses `--pull never`):

- harmonyos-go:1.24: `sha256:62f064eba7e9f7e7fab176912053e40b7f7c25cf4ddebda687281dc6eb451289`
- harmonyos-dev:24.04: `sha256:69d4ba018293d50ee8e325a16832c94a4d8d08abb3c1dfe84f60bc76bd1bff1a`

Raw evidence is under `dist/tests` and `dist/final-check.log`. CI workflow was
added for a pre-provisioned self-hosted runner; no remote CI job/runner was started.

## Behavior fixes exercised by these gates

- Reject JS embedded NUL rather than silently truncating ABI input.
- Preserve oversized newest log suffix and UTF-8 boundary in one HiLog record.
- Redact login URLs at every Go logging entrypoint.
- Return valid JSON on marshaling failure; nil statuses are explicit errors.
- Reject malformed native field types before UI rendering/dispatch.
- Do not apply stale device responses/open browser after view unmount.
- Clear device details on unauthenticated status transitions.
- Use control endpoint `/key?v=123` with netns dialer family in diagnostics;
  non-2xx responses are not marked successful.

## Acceptance boundary

No new device testing was performed or requested. Linux Node is not the Ark
runtime, and an HTTP fake is not the actual mobile control plane. Routine
logic/ABI/UI-state regression now has a complete server gate. New system
VPN/TUN/permissions/loader integration still needs its own platform acceptance.
See [testing](../testing.md), [architecture](../architecture.md), and
[contribution rules](../../CONTRIBUTING.md).
