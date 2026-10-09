# Compatibility patches

This directory records any source overlays or patches required to compile
Tailscale v1.86.2 for `GOOS=openharmony`.

The first build is intentionally attempted against the unmodified upstream Go
module. Every required change must include its upstream file, reason, and the
compiler error that justified it.
