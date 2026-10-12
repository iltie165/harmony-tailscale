# Project engineering contract

## Scope and architecture

- Read target code before editing. Do not change host packages, Docker images,
  signing configuration, module versions or upstream sources implicitly.
- Pinned upstream is `tailscale.com v1.86.2`. Product login/discovery uses a
  permission-free foreground official
  wgengine/ipnlocal core until an explicit VPN ON authorizes a two-phase
  transfer to the extension. At most one host owns the saved state. A healthy
  extension is reused for queries; normal ON/OFF retains that core. Its logical
  TUN attaches/detaches duplicated platform FDs without replacing the engine.
  Legacy tsnet exports remain for ABI compatibility/probes only. A state
  lease prevents duplicate owners; UI queries use the current host's private
  Unix LocalAPI.
  Fakes and permissive test-only packet filters are confined to tests.
- `core/main.go`: C exports, owned-string conversion, panic recovery. No business
  state machine here. `login.go`: IPN flow; `operations.go`: lifecycle/queries;
  `status.go`/`types.go`: response contracts; `logging.go`: bounded sanitized logs;
  `diagnostics.go`: injectable orchestration plus actual platform probes.
- Blocking core calls stay on NAPI async workers, not the UI thread. Start,
  close and control operations are serialized. Never call Close during Start.
- Every returned C string is owned by the caller and freed exactly once using
  `tailscale_ohos_string_free`. No Go pointers cross this boundary. Reject JS
  strings containing NUL before passing them to the C ABI.
- IPN subscription precedes an explicit login request. Existing Running/authUrl
  short-circuits are retained. Watchers and response bodies must always close.
- Native/UI errors must not become successful empty lists. Unmounted views must
  not apply asynchronous results or open a browser. VPN status must never be
  inferred from authentication. VPN ON requires the real interface, process
  protection and owner's independent state; cleanup failures remain visible.
  Normal OFF never releases the state lease or stops the extension/core. Only
  confirmed core failure, authorized foreground-to-extension handoff or
  deliberate service shutdown permits replacement.
  Page disposal releases observers, not accepted service commands. Go owns
  only a duplicated FD; never rely on fstat on a phone VPN descriptor.
- Recovery intent lives independently of service generations and display
  metadata. OFF/logout cancel and persist OFF before awaiting peer refreshes;
  late SDK work rechecks intent revision. The app supervisor may repair TUN or
  recover a missing/dead owner, never replace a confirmed healthy core due to
  control reconnect alone. Known auth/permission denial or a foreign visible
  VPN suspends attempts. Do not claim timers wake a suspended/killed runtime
  or that API24 distinguishes settings/manual stop from system termination.
- Keep login URLs, private keys and signing passwords out of source/logs. Login
  URLs are returned only for browser dispatch; all log entrypoints redact them.

## Required checks

- `make test`: offline race/vet, Go coverage, real Linux C ABI/NAPI execution,
  Mock failure injection, real LocalClient streaming, UI producer/consumer tests.
- `make check`: all of the above plus actual OpenHarmony ARM64 build and Hvigor
  ArkTS/HAP payload checks. Run before completing a behavior change.
- No dependency installation, signing password, external control plane or HDC
  is required by these gates. Fail closed if a cache/tool is missing.
- Each bug fix adds a regression exercising behavior at the affected boundary.
  Do not add a source regex assertion when a runtime test is feasible.
- Use Go standard-library/Node built-in/Python standard-library test tools and
  existing SDK compiler. No implicit dependency hydration in verification.
- Coverage gates apply to business domains, not fabricated device coverage.
  Preserve test JSON/coverage evidence under `dist/tests` (not committed).

## Verification claims

Distinguish pure/mock tests, Linux host ABI/NAPI execution, HarmonyOS target
compilation, and actual device evidence. Do not claim host Node proves Ark
runtime registration, mock TLS proves mobile networking, or a packaged HAP
proves device loading. Routine regressions must run without a phone; platform
changes still have a separately documented acceptance boundary.
