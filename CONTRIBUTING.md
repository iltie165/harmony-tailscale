# Contributing

This is an unofficial Alpha integration. Start with [scope](README.md),
[architecture](docs/architecture.md) and [build setup](docs/building.md).
Use Chinese or English in Issues and PRs. Follow respectful, technical discussion;
report abusive behavior to the repository maintainer through available GitHub
channels. No moderation team or response SLA is implied.

## Environment and commands

Bash, Git, Make and Python 3 are sufficient for `make lint`. The full offline
regression needs the pre-provisioned Docker images, fixed module cache and SDK
metadata documented in the build guide. Verification never hydrates dependencies.

```bash
make lint       # source syntax, local documentation links and project hygiene
make doctor     # read-only local prerequisites, no downloads
make test-ui    # production logic with mocked platform ports
make test       # Go race/vet/coverage, actual host C ABI/NAPI, UI contracts
make check      # full gate plus real ARM64/ArkTS/HAP target compilation
```

A new contributor cannot yet reproduce all toolchain provisioning from this
repository alone; see the explicit [gaps](docs/project-readiness.md). A missing
SDK is not a reason to manufacture device or target-build evidence.

## Change procedure

1. Open an Issue for a substantial design/behavior change; use small focused PRs.
2. Read the existing implementation and producer/consumer contract before editing.
3. For a behavior bug, add a failing runtime regression at the affected boundary.
4. Keep upstream pins, C ABI ownership and single-core state lease intact. Avoid
   unrelated dependency, system, signing or bundle identity changes.
5. Run `make check` for behavior or build changes. Documentation/template-only
   changes need `make lint`; state unrun target/device checks explicitly.
6. Review errors, cancellation, lifetimes and sensitive data. Include checks and
   outstanding platform acceptance in the PR template.

Fork PRs run SDK-free source checks on GitHub-hosted runners. Full checks need a
trusted, explicitly enabled `harmonyos` self-hosted runner; external fork code
is not run on it. A maintainer must review such contributions and run the full
checks in an appropriately isolated trusted environment before merging.
Do not use `pull_request_target` to execute untrusted code.

## Layout and docs

Go tests stay beside `core/` production code. Cross-language boundary tests and
host-only shims stay in `tests/`. Keep `AppScope/` and `entry/` in the standard
SDK layout. Current documentation belongs in `docs/`, release notes in
`docs/releases/`, one-off engineering records in `docs/archive/`.
Update the relevant index when adding a guide. Generated libraries, HAPs,
coverage, caches, credentials and device logs are not source.

Use UTF-8/LF, `gofmt`, existing `.editorconfig` and `.gitattributes`. Native host
compilation uses warnings-as-errors. Do not add tests that merely mirror source
text where a meaningful behavior test is possible.

## Releases and licensing

Read the [version policy](docs/versioning.md). VERSION is the project SemVer
source; HarmonyOS versionCode is a separate increasing upgrade ordinal. Prepare
version changes with `scripts/version.py set`; never rename an old signed binary
as a new release or rewrite a published tag. Current 0.1.0-alpha.1 is a development
target, not an existing public release.

Signing and publication are independent of PR checks. Preserve the last known
signed artifact, record source commit/version/checksums, and distinguish host
from target/device evidence. See [release checklist](docs/release-readiness.md).

The project's own code and documentation use the [MIT License](LICENSE).
Original code/documentation contributions are accepted under that same license.
Retain existing copyright and license notices; identify any third-party material
and its applicable terms. Do not submit material you lack permission to contribute.
No separate CLA is currently required. [Third-party terms](THIRD_PARTY.md),
including supplied artwork whose redistribution permission is still unconfirmed,
remain independent of the project's MIT license.
