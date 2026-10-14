# 3.3.2 — Bottom safe-area background

User reports that the top background is correct but a bottom strip remains
unpainted. The prior layout configured system-bar colors and full-screen layout,
but did not explicitly extend root rendering into the safe areas or set the
window background. The SDK documents navigationBarColor for the three-button
bar; it is not sufficient by itself to paint gesture-navigation surface gaps.

## Changes

- Set the window background to `#EEF6FC`, matching the bottom of the page,
  before system-bar setup and content loading. It remains set if full-screen
  layout is rejected, avoiding an unconfigured window-surface strip.
- Explicitly extend the root background into SYSTEM/CUTOUT safe areas on all
  edges. Preserve the existing gradient and add a matching solid fallback.
- Keep Scroll content's safe-area padding and rotation updates. Do not hide
  system bars or the gesture indicator or extend controls under them.
- No core, VPN, recovery, credentials, dependencies, SDK or signing changes.

## Verification

Complete `make check` passed: 275 passing leaf cases, zero failures/skips.
The window mock exercises background-before-bars/full-screen ordering, matching
bar colors, converted content insets, rotation, layout-denial fallback and
stage teardown. Real ARM64/ArkTS compilation and HAP payload checks passed.
Build evidence: `dist/ui-3.3.2-check.log`, `dist/tests/*`.

The signed/verified release is versionName `3.3.2`, versionCode `3003002`, at
`dist/hap/tailscale-probe-signed.hap`; the previous signed 3.3.1 is preserved.
Signature evidence: `dist/ui-3.3.2-sign.log`.

## Phone acceptance (not yet performed)

Close VPN in the app before cover-installing (do not uninstall). Check welcome,
dashboard, settings, diagnostics and details with short and long content, and
in portrait/landscape: bottom background should reach the gesture-navigation
area with no differently colored strip; last controls must remain above the
indicator. Check keyboard opening/closing and cold launch for surface flashes.
The top region must retain the previously confirmed appearance. Mock/window
tests and target compilation do not establish real phone visual correctness.
