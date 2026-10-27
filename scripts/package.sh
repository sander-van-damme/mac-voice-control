#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test "$(uname -s)" = Darwin
test "$(uname -m)" = arm64
swift build -c release --product MacVoice
binary_dir="$(swift build -c release --show-bin-path)"
app="dist/Mac Voice Control.app"
rm -rf "$app" dist/staging
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" dist/staging
cp "$binary_dir/MacVoice" "$app/Contents/MacOS/"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp LICENSE THIRD_PARTY_NOTICES.md "$app/Contents/Resources/"
# SwiftPM resource bundles must accompany the executable when dependencies supply them.
shopt -s nullglob
for bundle in "$binary_dir"/*.bundle; do cp -R "$bundle" "$app/Contents/Resources/"; done
identity="${SIGNING_IDENTITY:--}"
if [[ "$identity" == '-' ]]; then
  codesign --force --sign - --entitlements Resources/MacVoice.entitlements "$app"
  distribution=development-unsigned
else
  codesign --force --options runtime --timestamp --sign "$identity" --entitlements Resources/MacVoice.entitlements "$app"
  distribution=developer-id
fi
codesign --verify --strict --verbose=2 "$app"
plutil -lint "$app/Contents/Info.plist"
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  test "$identity" != '-'
  ditto -c -k --keepParent "$app" dist/notary-app.zip
  xcrun notarytool submit dist/notary-app.zip --keychain-profile "$NOTARY_PROFILE" --keychain "$SIGNING_KEYCHAIN" --wait --timeout 20m
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
  spctl --assess --type execute --verbose=2 "$app"
  rm dist/notary-app.zip
  distribution=notarized
fi
cp -R "$app" dist/staging/
ln -s /Applications dist/staging/Applications
cat > dist/staging/READ-ME.txt <<EOF
Mac Voice Control 0.1.0 — Apple Silicon, macOS 14.2+
Build type: $distribution
Drag Mac Voice Control to Applications, then open it and complete Setup.
Development builds are ad-hoc signed, not Apple-notarized; Gatekeeper may block them.
See the repository README for installation, permissions, privacy, and limitations.
EOF
dmg="dist/Mac-Voice-Control-arm64-$distribution.dmg"
rm -f "$dmg"
hdiutil create -volname 'Mac Voice Control' -srcfolder dist/staging -ov -format UDZO "$dmg"
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  codesign --force --timestamp --sign "$identity" "$dmg"
  xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --keychain "$SIGNING_KEYCHAIN" --wait --timeout 20m
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
fi
hdiutil verify "$dmg"
shasum -a 256 "$dmg" > "$dmg.sha256"
rm -rf dist/staging
echo "Packaged $dmg"
