# Implementation report

This is a working semantic-agent development slice, delivered in [draft PR #7](https://github.com/sander-van-damme/mac-voice-control/pull/7). It is not the complete real-world hands-free acceptance requested in the task. The implementation preserves the existing app and its native/portable split.

## A. Implementation summary

Known commands now route locally without Jev/OpenAI or screenshots. A bounded deterministic planner preserves compound goals as objectives with success conditions and pending/completed/blocked state. The agent can make image-free decisions from Chrome or AX semantics and request vision when needed. A real Chrome DOM adapter and bundled Swift Native Messaging host provide grounded browser observation/actions, per-site setup, expiry/connection/run binding and target validation.

Completion distinguishes sent input from observed outcomes. Search typing alone cannot prove completion; newest-result opening requires a uniquely dated visible match and verified destination. Unsafe/unknown operations retain confirmation. Native target checks, private field/caret guards, cancellation, deadlines and repeated-action bounds remain enforced. Native settling observes state and caches the next observation rather than always sleeping 220/750ms.

Local Parakeet Ultra, its pinned FluidAudio dependency, existing wake/voice modes, OAuth/API-key authentication, Keychain, screenshot geometry/redaction, confirmation UUID/expiry UI, CGEvent/AX execution and opt-in logging remain. Speech endpointing was deliberately left unchanged without hardware evidence.

## B. Architecture

Speech → InputRouter → CommandRouter → optional TaskPlanner → MacDesktop Chrome/AX/visual observation → structured/visual JevRequest → GoalLoop validation/confirmation → native/browser execution → TaskCompletionVerifier → next objective or completion.

DirectCommandExecuting bypasses the model path for known commands. DesktopControlling exposes perception preference, freshness, execution and state-based settling. TaskProgressTracker records objective state. CommandMetrics and SessionEvent feed existing application diagnostics/overlay. LanguageHelping remains optional and cached per task. No model-generated code/selector/shell interface was added.

## C. Important files

- Sources/VoiceCore/CommandRouter.swift: whole-command grammar and direct dispatch contract.
- Sources/VoiceCore/TaskPlan.swift: objectives, tracking, deterministic query extraction and verification.
- Sources/VoiceCore/Browser.swift: browser context, typed commands/replies and dated-result selection.
- Sources/VoiceCore/BrowserMailbox.swift: private bounded IPC and cancellable app connection.
- Sources/VoiceCore/TextIntent.swift and Input.swift: provenance and query-target restrictions.
- Sources/VoiceCore/ActionSafety.swift: deterministic semantic confirmation floor.
- Sources/VoiceCore/GoalLoop.swift and Jev.swift: integrated routing/plans, image-free requests, vision fallback and bounds.
- Sources/VoiceCore/Domain.swift and Performance.swift: semantic state and content-free metrics.
- Sources/MacVoice/MacDesktop.swift and Accessibility.swift: native integration, target/field freshness, direct actions and settling.
- Sources/MacVoice/BrowserSetup.swift, AppModel.swift and MacVoiceApp.swift: opt-in browser setup and application wiring.
- Sources/MacVoice/ScreenCapture.swift: separate acquisition and JPEG encoding timing.
- Sources/MacVoiceBrowserHost/main.swift and BrowserExtension/: executable browser transport and general DOM actions.
- Tests/VoiceCoreTests/, Tests/Browser/: policy, real Chromium DOM and native-host regression coverage.
- Benchmarks/, scripts/benchmark-report.py: repeatable fixture measurements and twenty-scenario coverage inventory.
- Package.swift, scripts/package.sh, .github/workflows/ci.yml: build products, nested-host packaging/signing and portable browser CI.
- README and docs/: actual architecture, installation, security, measurements and explicit limits.

## D. Validation

Unchanged baseline: 83 portable tests passed. Current local suite: 110 passed, zero final failures, on Linux x86_64 / Swift 6.2. Portable release compilation passed for VoiceCore, MacVoiceBrowserHost and VoiceBenchmarks. JavaScript/bash/Python/JSON/workflow YAML checks passed. The patch was checked against a clean base checkout.

Chromium 154: 20 checks passed, including five complete workflows through the production Swift GoalLoop. DOM execution is real in an isolated world; Jev choices and Chrome API transport are injected. The native Swift host separately passed framed-stdio, permission, connection-binding, oversized-frame and wrong-origin checks. These are not complete installed-extension or Mac desktop tests.

Final GitHub CI at source 0d44e70 passed all jobs in run 41074646897: Ubuntu 24.04 passed 110 core tests, 20 real-DOM checks (Chromium 151, injected Chrome API transport/mock Jev) and the native-host tests; Apple Silicon macOS compiled the app, passed 129 tests and packaged/uploaded the signed development DMG. [Download the artifact](https://github.com/sander-van-damme/mac-voice-control/actions/runs/41074646897/artifacts/12986154216). Documentation-only follow-ups preserve that tested application code. The first portable CI attempt failed because ubuntu-latest selected unsupported Ubuntu 26.04; pinning the job to Ubuntu 24.04 fixed the failure. See [validation record](validation.md) for the latest authoritative results.

Real microphone/code-switching, live Jev/OpenAI decisions, TCC, normal-profile extension installation/permissions, Chrome-to-app Native Messaging, multiple displays/profiles/windows and actual hands-free tasks remain unperformed. macOS CI does not replace them.

## E. Performance evidence

Five real-DOM/mock-model workflows each used ten decision-provider calls, six dispatched actions, zero screenshots and zero language calls. Their measured fixture median first action was 21.421ms; median completion was 482.358ms. These figures exclude real inference/network/speech/native IPC latency and are not Mac performance claims. Five direct-command scenarios, ten mock-native runs each, made zero model calls and captured/sent zero screenshots. No p95 is reported for these small samples.

A synthetic 300,000-byte image payload serialized to a 408,570-byte visual request versus a 5,997-byte structured request. The payload was not a captured/decoded JPEG; this is request-size evidence only. There is no measured before/after real-Mac task latency or failure-rate comparison. Stage timers can nest; total latency uses an independent wall-clock measurement.

## F. Remaining limitations

The deterministic clause grammar is limited, and there is no autonomous structural replanning. Generic objective completion still relies on independent Jev evidence plus freshness. Newest selection covers visible uniquely dated query-free links, not pagination, hidden records or opaque query identities. Query-bearing navigation can be dispatched but cannot be fully verified from sanitized URLs. Programmatic events may not work with every web framework. Complex editors, frames, shadow DOM and canvas need AX/vision. Uncertain mutations stop instead of replaying.

There is no new OCR backend, learned workflow store, comprehensive replacement/general field-value model, spoken feedback, or measured endpoint/VAD improvement. Native input that has already been posted and browser work already delegated cannot be recalled. Several direct native actions report dispatched/unverified until stronger outcome evidence is implemented. Metrics do not yet include exact provider retry totals, all language-provider usage costs or real speech task benchmarks.

## G. Next priorities

1. Complete real TCC/Chrome installation, permission, profile/window and spoken-Stop acceptance with the packaged Apple Silicon build.
2. Collect live Jev/ASR task trajectories and measured median/p95 latency, task success, false actions and intervention rates.
3. Add typed uncertain-outcome recovery and bounded objective replanning without non-idempotent replay.
4. Extend evidence/identity for query-based links, pagination, native folders, supported field replacement and rich editors.
5. Use measurements to optimize speech endpointing/IPC and then add optional spoken feedback and inspectable verified workflows.
