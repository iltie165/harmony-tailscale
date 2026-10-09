#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
image=${HARMONY_DEV_IMAGE:-harmonyos-dev:24.04}
signing_dir=${HARMONY_SIGNING_DIR:-/home/zackli/harmony-signing}
keystore=${HARMONY_KEYSTORE_FILE:-$signing_dir/debug.p12}
app_cert=${HARMONY_APP_CERT_FILE:-$signing_dir/lch-phone.cer}
profile=${HARMONY_PROFILE_FILE:-$signing_dir/tailscala-hos-debug.p7b}
unsigned_hap=${1:-$project_root/dist/hap/tailscale-probe-unsigned.hap}
signed_hap=${2:-$project_root/dist/hap/tailscale-probe-signed.hap}
bundle_name=com.ezoo.tailscaleprobe
compatible_api=${HARMONY_COMPATIBLE_API:-24}

: "${HARMONY_KEYSTORE_PASSWORD:?set HARMONY_KEYSTORE_PASSWORD without writing it to a file}"
key_password=${HARMONY_KEY_PASSWORD:-$HARMONY_KEYSTORE_PASSWORD}
key_alias=${HARMONY_KEY_ALIAS:-}

for required in "$keystore" "$app_cert" "$profile" "$unsigned_hap"; do
  if [[ ! -f "$required" ]]; then
    echo "missing required file: $required" >&2
    exit 1
  fi
done

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

openssl cms -verify -binary -inform DER -in "$profile" -noverify \
  -out "$tmp_dir/profile.json" >/dev/null 2>&1
profile_bundle=$(jq -r '.["bundle-info"]["bundle-name"] // empty' "$tmp_dir/profile.json")
if [[ "$profile_bundle" != "$bundle_name" ]]; then
  echo "profile bundle mismatch: expected $bundle_name, got ${profile_bundle:-<empty>}" >&2
  exit 1
fi
cert_count=$(grep -c -- '-----BEGIN CERTIFICATE-----' "$app_cert" || true)
if (( cert_count < 2 )); then
  echo "app certificate file must contain the complete certificate chain" >&2
  exit 1
fi

mkdir -p "$(dirname "$signed_hap")"

docker run --rm \
  -e HARMONY_KEYSTORE_PASSWORD \
  -e HARMONY_KEY_PASSWORD="$key_password" \
  -e HARMONY_KEY_ALIAS="$key_alias" \
  -e HARMONY_COMPATIBLE_API="$compatible_api" \
  -e HARMONY_OUTPUT_NAME="$(basename "$signed_hap")" \
  -v "$keystore:/signing/debug.p12:ro" \
  -v "$app_cert:/signing/app-cert-chain.cer:ro" \
  -v "$profile:/signing/profile.p7b:ro" \
  -v "$unsigned_hap:/input/app-unsigned.hap:ro" \
  -v "$tmp_dir:/work" \
  -v "$(dirname "$signed_hap"):/output" \
  "$image" bash -lc '
    set -euo pipefail
    sign_tool=/opt/harmony/command-line-tools/sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar
    alias_name=$HARMONY_KEY_ALIAS
    if [[ -z "$alias_name" ]]; then
      alias_name=$(keytool -list -v -storetype PKCS12 \
        -keystore /signing/debug.p12 \
        -storepass "$HARMONY_KEYSTORE_PASSWORD" 2>/dev/null \
        | sed -n "s/^Alias name: //p" | head -1)
    fi
    if [[ -z "$alias_name" ]]; then
      echo "could not determine the private-key alias" >&2
      exit 1
    fi

    java -jar "$sign_tool" sign-app \
      -mode localSign \
      -keyAlias "$alias_name" \
      -keyPwd "$HARMONY_KEY_PASSWORD" \
      -appCertFile /signing/app-cert-chain.cer \
      -profileFile /signing/profile.p7b \
      -profileSigned 1 \
      -inFile /input/app-unsigned.hap \
      -signAlg SHA256withECDSA \
      -keystoreFile /signing/debug.p12 \
      -keystorePwd "$HARMONY_KEYSTORE_PASSWORD" \
      -outFile "/output/$HARMONY_OUTPUT_NAME" \
      -compatibleVersion "$HARMONY_COMPATIBLE_API" \
      -signCode 1

    java -jar "$sign_tool" verify-app \
      -inFile "/output/$HARMONY_OUTPUT_NAME" \
      -outCertChain /work/verified-cert-chain.cer \
      -outProfile /work/verified-profile.p7b
  '

"$project_root/scripts/verify-hap.sh" "$signed_hap"
echo "Signed HAP: $signed_hap"
