#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
image=${HARMONY_DEV_IMAGE:-harmonyos-dev:24.04}
hap=${1:-"$project_root/dist/hap/tailscale-probe-unsigned.hap"}

[[ -f "$hap" ]] || { echo "missing HAP: $hap" >&2; exit 1; }

archive=$(unzip -Z1 "$hap")
for entry in \
  libs/arm64-v8a/libtailscale_napi.so \
  libs/arm64-v8a/libtailscale_ohos.so \
  libs/arm64-v8a/libc++_shared.so \
  ets/modules.abc \
  module.json; do
  grep -Fxq "$entry" <<<"$archive" || { echo "missing HAP entry: $entry" >&2; exit 1; }
done

python3 - "$hap" <<'PY_CHECK'
import json
import sys
import zipfile
with zipfile.ZipFile(sys.argv[1]) as archive:
    app = json.loads(archive.read('module.json'))['app']
    assert app['compileSdkType'] == 'HarmonyOS', app
    assert app['minAPIVersion'] % 1000 == 24, app
    assert app['targetAPIVersion'] % 1000 == 26, app
    assert app['bundleName'] == 'com.ezoo.tailscaleprobe', app
    module = json.loads(archive.read('module.json'))['module']
    assert any(ext['name'] == 'VpnProbeAbility' and ext['type'] == 'vpn' and
               ext.get('exported') is False for ext in module['extensionAbilities']), module
    for name in archive.namelist():
        assert not name.endswith('.node') and 'libtailscale_host' not in name, name
print('HAP metadata/API/host-artifact exclusion: PASS')
PY_CHECK

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
unzip -p "$hap" libs/arm64-v8a/libtailscale_napi.so >"$work_dir/libtailscale_napi.so"
unzip -p "$hap" libs/arm64-v8a/libtailscale_ohos.so >"$work_dir/libtailscale_ohos.so"
unzip -p "$hap" libs/arm64-v8a/libc++_shared.so >"$work_dir/libc++_shared.so"

docker run --rm --pull never --network none \
  -v "$work_dir:/verify:ro" \
  "$image" bash -lc '
    set -euo pipefail
    for library in /verify/*.so; do
      elf_header=$(readelf -h "$library")
      grep -Eq "Machine:[[:space:]]+AArch64" <<<"$elf_header"
      grep -Eq "Class:[[:space:]]+ELF64" <<<"$elf_header"
      grep -Eq "Type:[[:space:]]+DYN" <<<"$elf_header"
    done
    napi_dynamic=$(readelf -d /verify/libtailscale_napi.so)
    grep -Fq "Shared library: [libtailscale_ohos.so]" <<<"$napi_dynamic"
    if grep -Eq "Shared library: \[[^]]*/" <<<"$napi_dynamic"; then
      echo "packaged NAPI library contains an absolute DT_NEEDED path" >&2
      exit 1
    fi
    if grep -Eq "\((RPATH|RUNPATH)\)" <<<"$napi_dynamic"; then
      echo "packaged NAPI library contains a build-time RPATH/RUNPATH" >&2
      exit 1
    fi
    napi_symbols=$(readelf -Ws /verify/libtailscale_napi.so)
    grep -q "napi_module_register" <<<"$napi_symbols"
    grep -q "napi_define_properties" <<<"$napi_symbols"
    napi_strings=$(strings -a /verify/libtailscale_napi.so)
    for property in getVersion getStatus getLogs start login logout onlinePeers diagnostics close inspectVpnDescriptor tailscale_napi; do
      grep -Fxq "$property" <<<"$napi_strings"
    done
    go_symbols=$(readelf -Ws /verify/libtailscale_ohos.so)
    for symbol in tailscale_ohos_start tailscale_ohos_status tailscale_ohos_login tailscale_ohos_logout tailscale_ohos_online_peers; do
      grep -Eq "[[:space:]]${symbol}$" <<<"$go_symbols"
    done
    go_relocations=$(readelf -rW /verify/libtailscale_ohos.so)
    if grep -q R_AARCH64_TLS_TPREL64 <<<"$go_relocations"; then
      echo "forbidden TLS relocation in packaged Go library" >&2
      exit 1
    fi
  '

echo "HAP native payload verification: PASS"
