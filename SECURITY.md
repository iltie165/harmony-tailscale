# Security policy

## Supported scope

Only the latest source on `main` is a security-fix target. The current app is
Alpha; no LTS branches, response-time SLA or completed security audit is claimed.
Old device-scoped debug builds are not supported public releases.

## Reporting a vulnerability

Do not put credentials, private state or exploitable details in public Issues.
Use GitHub's **Report a vulnerability** on the repository Security tab when
private vulnerability reporting is enabled. If it is unavailable, open a public
Issue containing only a request for a private reporting channel; the maintainer
must arrange that channel before any sensitive details are exchanged.

Private reporting is a repository setting, not something this file enables.
Its activation remains on the [publication checklist](docs/project-readiness.md).
No private address or response-time commitment is invented here.

Include the affected commit/version, platform/API, impact and a minimal
reproducer over the agreed private channel. Redact login URLs, node keys,
profiles, auth tokens, signing passwords and personal metadata.

## Relevant boundaries

This app owns system VPN descriptors and persisted node state. Reports involving
state-lease overlap, IPC command ownership, stale authorization, FD cleanup,
credential exposure, NAPI memory ownership or route/protection bypass are welcome.
Host tests and target compilation are not a mobile security audit.

Report defects in upstream Tailscale itself through its upstream security
process; do not assume this unofficial wrapper is an upstream support contact.
