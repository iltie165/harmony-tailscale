# Third-party materials and attribution

This is an unofficial community integration. Names identify compatibility and
upstream software; they do not imply endorsement or grant trademark rights.

| Component | Pin/source | License / status |
| --- | --- | --- |
| Tailscale core | `tailscale.com v1.86.2`, commit `d72494bac7a2fb6b6a01715cfc5bcc903dbd7594` | Main upstream license BSD-3-Clause plus additional patent grant; preserved in [third_party/tailscale](third_party/tailscale/README.md) |
| Linked Go modules | [57-module inventory](third_party/linked-modules.json), derived from actual binary metadata | Supplied texts collected in [THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt); per-file applicability/manual audit still separate |
| OpenHarmony Go toolchain/runtime | Existing build image, Go 1.24.5 | Source provenance/commit and runtime notice set still to be recorded |
| HarmonyOS SDK, Hvigor, bundled native runtime | Official API 26 toolchain | SDK terms and redistributed `libc++_shared.so` notice obligations require review; SDK not vendored |
| Icons/artwork | `AppScope/resources/` and `entry/src/main/resources/` | Supplied PNG and vector provenance/redistribution permission still to be confirmed |

This repository's own code and documentation use the [MIT License](LICENSE).
It does not relicense third-party code, SDKs or supplied artwork. Upstream can
also contain per-file/subdirectory terms; its main license alone is not a
completed review of everything linked or packaged.

## Before distributing a binary

1. Derive the linked module list from the actual build, not just all indirect
   requirements in go.mod; record exact versions and source/checksum evidence.
2. Review applicable license/NOTICE/PATENTS files for those modules, Go runtime
   and packaged native libraries; preserve notices in release materials.
3. Confirm ownership/redistribution permission for every supplied image/vector.
4. Publish the resulting notice bundle/SBOM with the release. This document is
   an inventory and gap record, **not** a completed SBOM or compliance claim.

Upstream source: https://github.com/tailscale/tailscale/tree/v1.86.2.

## Packaged local notice bundle

`make build` regenerates notices from the actual linked Go binary metadata and existing
verified cache, offline. The bundle includes supplied Go and SDK LLVM texts and is
packaged for offline app viewing. Collection is not a completed legal audit, SPDX
classification or confirmation of artwork redistribution rights. Toolchain source
provenance/reproduction and SDK redistribution applicability remain to be reviewed.
