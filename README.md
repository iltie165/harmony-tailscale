# harmony-tailscale

HarmonyOS ARM64 C ABI wrapper around the official Tailscale Go core.

## Pinned inputs

- Tailscale module: `tailscale.com v1.86.2`
- Tailscale tag commit: `d72494bac7a2fb6b6a01715cfc5bcc903dbd7594`
- Required Go version: `1.24.4` (the build image currently provides `1.24.5`)
- Build image: `harmonyos-go:1.24`
- Target: `GOOS=openharmony GOARCH=arm64 CGO_ENABLED=1`

## Build

Dependencies must already exist in `.cache/gomod`; the build runs with Docker
networking disabled and `GOPROXY=off`.

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
