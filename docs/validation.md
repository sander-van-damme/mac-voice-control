# Validation record

## 27 October 2026 — independent follow-up

The application foundation from PR #1 was reviewed independently and extended in [PR #2](https://github.com/sander-van-damme/mac-voice-control/pull/2). Review sources and the before-implementation decisions are in [research-follow-up.md](research-follow-up.md).

| Check | Exact evidence | Outcome |
|---|---|---|
| Portable core tests | Linux x86_64, Swift 6.2.1; final core at `f9826772a8b8bc34b7b66b23399b457d5a79d14f` | 52 XCTest cases passed, 0 failures; no API key or speech weights |
| Native tests, GUI compilation, release compilation, app signature integrity, DMG integrity and artifact upload | [macOS run 40503721165](https://github.com/sander-van-damme/mac-voice-control/actions/runs/40503721165), packaged revision `786ed994eb9c7839a8236417897eb3a575d7fd81`; Apple Silicon, Xcode 26.3 / Swift 6.2.4 | 65 XCTest cases passed; development DMG produced |
| Workflow and auxiliary syntax | actionlint 1.7.7, bash syntax, Python AST, plist/JSON parsing, manual fixture JavaScript syntax, git diff checks | Passed |

[Download the development artifact](https://github.com/sander-van-damme/mac-voice-control/actions/runs/40503721165). The artifact contains the DMG, its SHA-256, and the pinned dependency lockfile. It requires GitHub sign-in and expires according to the run's retention policy. It is ad-hoc signed and not notarized. The final documentation-only commit does not change the packaged application code or bundled notices.

New executable coverage includes decision/observation binding, stale confirmation IDs, delayed expiry timers, expiry during target checks, cancellation at the execution boundary and during consent, bounded correction authority, missing audio chunks, stale transcripts, bilingual synthetic routing, GUI download cancellation/retry, late speech after Stop, sleep-triggered stopping, local visual-pixel changes, and window-server fallback identity/occlusion checks. Synthetic native windows/pixels and a simulated sleep notification do not establish real desktop or hardware behavior.

Implemented follow-up behavior includes a screenshot-only fallback when an app exposes no AX window, explicit screenshot/window coordinate metadata for Jev, deadlines that advance across sleep, and complete bundled fastcluster BSD attribution. The source and packaged development application are delivered; the full real-world product acceptance criteria remain unverified.

The remaining release gates are unchanged: real microphone Dutch/English/code-switching accuracy, live TypeSafe image decisions, actual Chrome/native-app actions, screen capture on multiple displays, permission recovery and hardware interruption, calibrated confidence thresholds, measured end-to-end performance, Developer ID signing and Apple notarization. No credentials or real Mac desktop were supplied for these checks. Optional Codex, OCR and automatic zoom refinement remain documented later milestones.

## 26 October 2026 — original implementation

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
