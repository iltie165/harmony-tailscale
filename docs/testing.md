# Server-first verification

## Required gate

```bash
make test
make check
```

Both run unattended without a phone, an actual Tailscale account, signing
credentials, public network access or new package installation. `make check`
adds the real target compiler, NAPI linkage, ArkTS compilation and packaged HAP
inspection. All containers default to offline networking. Missing dependencies
fail explicitly instead of downloading or asking for HDC.

## Test lanes

| Lane | What actually runs | Faults/assertions |
| --- | --- | --- |
| Go unit + race | Production business code behind injected ports | Login events, order, backend failures, timeout/cancel, independent bounded status snapshot, watcher cleanup, lifecycle and locks, filtering/sorting, JSON, sanitized bounded logs |
| LocalAPI integration | Pinned `local.Client` + real streaming decoder, local HTTP fake | URL notification, daemon error, malformed stream, timeout, HTTP failure and response close |
| C ABI integration | Real Linux `c-shared` library loaded with ctypes | Export/version, null/invalid inputs, JSON errors, independent buffers, actual free, concurrent reads |
| NAPI real-core integration | Production bridge + Node N-API + actual Go `.so` | Export contract, argument errors/NUL, real Promises, operation JSON, conversion/free and repeated/concurrent calls |
| NAPI fault integration | Same bridge + minimal SDK wrappers/mock C ABI | Null/empty results, SDK allocation/queue failure, recovery, delayed workers off event loop, one-time URL not logged, newest atomic log tail |
| UI/contract | Actual page methods and model via SDK TypeScript, mocked platform/native APIs | Session restoration, browser fallback/failure, stale-card clearing, logout, timer bounds, background gating, unmount guards, malformed field types |
| Cross-language contract | Go-generated success/failure fixtures decoded by ClientModel | Producer field names/types, peer and lifecycle envelopes, error propagation |
| Target build | OpenHarmony ARM64 Go/Native and Hvigor ArkTS | ELF/TLS, C exports, basename-only NAPI dependency, no build-time RPATH, HAP content |

No server test logs into the public control plane or changes a user's Tailnet.
Host integration deliberately does not start a real internet-authenticated
backend; business/network events are supplied by Mock ports/local HTTP instead.

## Coverage gates

Statement counters in `dist/tests/go.cover`, not test counts, enforce:

| Go business domain | Minimum |
| --- | --- |
| Login flow | 90% |
| Lifecycle and queries | 95% |
| Status/conversion/filtering | 95% |
| Logs | 90% |
| Runtime state | 95% |
| JSON wire types | 100% |

The aggregate Go percentage also includes platform probes and C adapters and is
reported separately. It is **not** a coverage claim for upstream Tailscale,
ArkUI rendering, the Ark runtime, HarmonyOS APIs or the device kernel. Do not
inflate it by labeling excluded platform code as tested.

## Evidence

- `dist/tests/go.jsonl`: race-enabled Go test/subtest results.
- `dist/tests/go.cover`, `go-coverage.txt`, `coverage-summary.json`: measured coverage.
- `dist/tests/contracts/*.json`: responses from the real Go producer.
- `dist/tests/libtailscale_host.so`, `tailscale-{real,mock}.node`: host-only artifacts;
  never package them in a HAP.
- `dist/tests/hilog-{real,mock}.txt`: host-shim log/privacy evidence, not device HiLog.
- `dist/hap/tailscale-probe-unsigned.hap`: target compile/packaging artifact.

The NAPI host test shim is under `tests/host` and is included only by the test
compiler command; production CMake uses the real HarmonyOS SDK. Mock C ABI
asserts all returned string allocations are freed on process exit. This is not
an exhaustive memory/leak sanitizer of the Go runtime or platform SDK.

## What still needs platform acceptance

Routine changes to filters, JSON, login event logic, error handling, timers or
page state should not require a phone to locate defects. Initial/new platform
integration still requires a separate, small smoke acceptance:

- HarmonyOS loader and Ark NAPI registration (not Linux Node).
- Real UIAbilityContext browser dispatch and foreground events.
- App sandbox, mobile socket policy and network changes.
- ArkUI rendering/accessibility on device dimensions.
- System VPN/TUN, routes, DNS and background lifecycle when implemented.

The old 3.0.6 login/peer workflow already has user-reported device evidence; this
refactor has server/target-build evidence only. Tests do not manufacture new
device evidence. No new device test is required to run the engineering gate.
