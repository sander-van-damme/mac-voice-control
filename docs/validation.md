# Validation record — 26 October 2026

This is an experimental development build, not a validated production voice assistant.

## Executed checks

| Check | Evidence | Outcome |
|---|---|---|
| Native Apple Silicon build, tests, release compilation, app signing integrity, DMG integrity | [macOS run 40399933444](https://github.com/sander-van-damme/mac-voice-control/actions/runs/40399933444), source fa4df786 | Passed; 33 tests; downloadable development DMG produced |
| Expanded portable core and HTTP suite | Linux Swift 6.2.3 container, source 721073a2 | Passed; 37 XCTest cases; no API key or model weights |
| Expanded native suite and packaging | [macOS run 40400528741](https://github.com/sander-van-damme/mac-voice-control/actions/runs/40400528741), source 721073a2 | Passed; includes native pixel redaction and padding checks plus portable suite |
| Packaging/signing script syntax, plist/XML parsing, Python live-probe syntax | Local static checks | Passed |

The CI app build and package are the actual `MacVoice` product, with the reviewed FluidAudio revision. The native screenshot tests encode/decode real synthetic pixels and verify redaction position, orientation, padding, and image size; they do not capture a real user's screen.

The initial macOS build caught an invalid multi-variable SwiftUI `@Published` declaration. That was fixed, rebuilt, and tested. No failed check is presented as successful.

Current branch/PR status and artifacts are available at [PR #1](https://github.com/sander-van-damme/mac-voice-control/pull/1). Later revisions must pass their own CI; the links above preserve the historical evidence instead of claiming that an old artifact contains later edits.

## Not executed / still required

- A live Jev request: no TypeSafe key was provided. `scripts/live-jev-smoke.py` is ready for an opt-in protocol test.
- Real microphone recognition and Dutch–English code-switching accuracy/latency. Text routing is tested; speech accuracy is not inferred from it.
- Real Chrome/native-app end-to-end actions, multiple displays, permissions, sleep/wake, and interrupted hardware input on a user's Mac. See the repeatable checklist in testing.md.
- Developer ID signing and Apple notarization: no Apple credentials were configured. Produced artifacts are ad-hoc development builds.
- Measured application end-to-end latency, WER, false-activation rate, and visual pointing accuracy. No invented benchmark numbers are supplied.

## Requirements review

Implemented: native GUI and menu-bar controls; setup/key/permission/model workflow; local multilingual ASR integration; wake-phrase and explicit dictation routing; current screenshots and supplementary AX input; experimental Jev Box/presence contract; fixed action registry; multi-step observation loop; stale-window/target and named-app guards; cancellation; expiring confirmations; secure-field filtering/masking; bounded context and execution; HTTP validation/retries; metrics; tests; research/architecture/licensing; CI and DMG artifacts; optional signing/notarization and draft Releases.

Deliberately deferred: optional Codex App Server escalation, Vision OCR, learned VAD, automatic crop refinement, and broader desktop acceptance/calibration. The baseline has no generative text authoring, arbitrary shell action, or unsupported claim of production reliability.

The source and installable development artifact goals are achieved. The full product acceptance criteria involving live voice and computer control remain unverified until the real-Mac checklist is completed.
