# Build, signing, and release

## Workflows

`ci.yml`: pull requests and pushes to main/codex branches build and test on `macos-15` (Apple Silicon), explicitly selecting Xcode 26.3. It creates an ad-hoc signed app and a `development-unsigned.dmg` artifact. No signing secrets or paid API key are passed into this workflow. Dependency sources are cached; model weights are not downloaded.

`release.yml`: a `v*` tag or manual dispatch tests and packages the same product. Without credentials it still uploads an unsigned development DMG. With a Developer ID certificate it signs the hardened-runtime app. With complete notarization credentials it submits/staples both app and DMG. Version tags create a **draft** GitHub Release containing the packaged files. Review validation and signing status before publishing the draft. Manual dispatch only uploads an artifact.

Action dependencies are pinned to commit SHAs. The Swift package dependency is pinned to a reviewed FluidAudio revision and a resolved lockfile is retained with the artifact. Xcode runner images can retire older versions: update the explicit path deliberately after checking the [runner manifest](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md).

## Optional repository secrets

| Secret | Purpose |
|---|---|
| APPLE_CERTIFICATE_BASE64 | Base64-encoded Developer ID Application `.p12` export |
| APPLE_CERTIFICATE_PASSWORD | Password for that export |
| SIGNING_IDENTITY | Full Developer ID Application identity name |
| APPLE_ID | Apple developer account used for notarization |
| APPLE_TEAM_ID | Developer team identifier |
| APPLE_APP_PASSWORD | App-specific password for notarization |

Configure these in GitHub Settings → Secrets and variables → Actions. They are never committed, printed, or copied into the app. The certificate is imported into a temporary CI keychain, the export is removed immediately, and cleanup runs even on failure. The TypeSafe key is always entered by the end user in the app; it is not a build secret.

If a certificate is configured but incomplete/invalid, the release build fails rather than silently claiming a signed release. If notarization credentials are absent, a certificate-only artifact says `developer-id`, not `notarized`. A failed notarization fails the build; it does not downgrade the artifact.

## Versioning and verification

Update CFBundleShortVersionString and CFBundleVersion in Resources/Info.plist and the package readme before tagging a release. Use matching `vMAJOR.MINOR.PATCH` tags. The DMG contains the .app and an Applications alias. SHA-256 accompanies every artifact.

Before a public release:

1. Ensure build/tests/package checks pass for the exact commit.
2. Download the artifact produced by that run; do not package a different checkout.
3. Install from Finder on a separate Mac account and complete the manual tests in testing.md.
4. Verify `notarized` distribution status, staple, Gatekeeper assessment, and model first-run download on a clean machine.
5. Publish the draft Release only after reviewing the known limitations and validation record.

Apple requires the Developer ID account/certificate and notarization credentials. None were supplied during development; an ad-hoc development build is not represented as an Apple-approved release.
