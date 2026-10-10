# Development workflow

## Prerequisites (already present on the development server)

- Bash, Make, Python 3 and Docker.
- Images `harmonyos-go:1.24` and `harmonyos-dev:24.04`, including SDK, host GCC,
  Node/TypeScript and OpenHarmony-aware Go. Gates never install packages.
- Pre-hydrated, verified module cache at `.cache/gomod`, or an absolute
  `HARMONY_GOMODCACHE` path. Build caches stay in `.cache/gobuild*`.
- HAP/Hvigor package metadata must be hydrated beforehand. An empty/new runner
  is not automatically hydrated by CI; installation or environment changes
  require explicit authorization.

## Daily commands

```bash
make test        # offline server regression, no device/account/secrets
make test-ui     # UI-only; Go contract fixture check skips if not generated
make check       # required full gate, including ARM64, ArkTS and HAP
```

Use `HARMONY_GO_IMAGE`/`HARMONY_DEV_IMAGE` only for an intentional toolchain
change. Normal Go builds and all tests/inspection run with `--network none`,
`GOPROXY=off`, `GOSUMDB=off`, and `-mod=readonly`; module cache mounts read-only.
Hvigor also defaults to `--network none`. Dependency hydration is a separate,
explicitly authorized operation, not a fallback when tests fail.

## Change procedure

1. Read the existing implementation and response contract.
2. Add a failing behavior/edge-case regression at the affected layer.
3. Make the smallest change, keeping upstream code and ABI version stable unless
   the external contract intentionally changes.
4. Run `make check`. Retain machine-readable Go results, statement coverage,
   NAPI log evidence and HAP payload verification.
5. Review the diff for ownership/lifecycle/error regressions. State any platform
   acceptance still pending; never ask the user to debug ordinary business logic
   that can be exercised with injected ports on the server.
6. Signing/distribution is independent. Do not overwrite the last known signed
   release with an unsigned file. Do not store P12 passwords or private keys.

`.editorconfig` and `.gitattributes` set UTF-8/LF and formatting conventions;
Go uses `gofmt`, native compilation uses warnings-as-errors in host tests.
Generated libraries, HAPs, coverage, SDK caches and device logs are not source.

## CI

`.github/workflows/check.yml` runs `make check` on a trusted pre-provisioned
`self-hosted, Linux, X64, harmonyos` runner and saves evidence artifacts. It is
only a checked-in workflow here; no GitHub run or runner has been created.
Provision the pinned images, a read-only module cache (default
`/opt/harmony-ci/gomod`, override repository variable `HARMONY_CI_MODULE_CACHE`),
and warmed Hvigor metadata before enabling it. Compiler/Hvigor caches are
preserved by the workflow. An ordinary hosted runner lacks this SDK/toolchain.
Do not expose this trusted Docker-enabled runner to untrusted fork code.

See [testing boundaries](docs/testing.md) and [architecture](docs/architecture.md).
