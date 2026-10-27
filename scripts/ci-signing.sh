#!/bin/bash
set -euo pipefail
# Never enable shell tracing in this script. Secrets are environment inputs only.
if [[ -z "${APPLE_CERTIFICATE_BASE64:-}" ]]; then
  echo 'Signing credentials absent; producing an unsigned development artifact.'
  exit 0
fi
: "${APPLE_CERTIFICATE_PASSWORD:?Missing certificate password}"
: "${SIGNING_IDENTITY:?Missing Developer ID identity}"
signing_dir="$RUNNER_TEMP/macvoice-signing"
mkdir -p "$signing_dir"
chmod 700 "$signing_dir"
keychain="$signing_dir/build.keychain-db"
keychain_password="$(openssl rand -hex 24)"
echo "::add-mask::$keychain_password"
printf '%s' "$APPLE_CERTIFICATE_BASE64" | base64 --decode > "$signing_dir/certificate.p12"
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$signing_dir/certificate.p12" -P "$APPLE_CERTIFICATE_PASSWORD" -A -t cert -f pkcs12 -k "$keychain" >/dev/null
security set-key-partition-list -S apple-tool:,apple: -k "$keychain_password" "$keychain" >/dev/null
security list-keychain -d user -s "$keychain"
rm "$signing_dir/certificate.p12"
echo "SIGNING_KEYCHAIN=$keychain" >> "$GITHUB_ENV"
echo "SIGNING_IDENTITY=$SIGNING_IDENTITY" >> "$GITHUB_ENV"
if [[ -n "${APPLE_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
  xcrun notarytool store-credentials macvoice-ci --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" --keychain "$keychain" >/dev/null
  echo 'NOTARY_PROFILE=macvoice-ci' >> "$GITHUB_ENV"
fi
