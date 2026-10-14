#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
image=${HARMONY_DEV_IMAGE:-harmonyos-dev:24.04}
signed_name=$(python3 "$project_root/scripts/version.py" artifact signed)
hap=${1:-"$project_root/dist/hap/$signed_name"}

if [[ ! -f "$hap" ]]; then
  echo "missing signed HAP: $hap" >&2
  echo "Pass a signed HAP as the first argument." >&2
  exit 1
fi
python3 "$project_root/scripts/version.py" check --hap "$hap"

mkdir -p "$project_root/dist/device-logs"

docker run --rm --network host --privileged \
  -v /dev/bus/usb:/dev/bus/usb \
  -v "$hap:/tmp/tailscale-probe-signed.hap:ro" \
  -v "$project_root/dist/device-logs:/logs" \
  "$image" bash -lc '
    set -euo pipefail
    hdc=/opt/harmony/command-line-tools/sdk/default/openharmony/toolchains/hdc
    target=$($hdc list targets | tr -d "\r" | head -1)
    if [[ -z "$target" || "$target" == "[Empty]" ]]; then
      echo "no HarmonyOS device detected by hdc" >&2
      exit 2
    fi
    $hdc install -r /tmp/tailscale-probe-signed.hap
    $hdc shell aa force-stop com.ezoo.tailscaleprobe || true
    $hdc shell aa start -a EntryAbility -b com.ezoo.tailscaleprobe
    echo "Open Settings > Diagnostics and logs > Verify system VPN capability."
    echo "Streaming UI, native and VPN extension logs; press Ctrl-C after the result appears."
    $hdc shell hilog -Q domainon
    $hdc shell hilog | grep -E "TailscaleProbe|TailscaleNAPI|VpnCapabilityProbe|Go runtime|tsnet" | tee /logs/tailscale-probe-hilog.log
  '
