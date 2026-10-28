# Architecture

## Boundaries

`VoiceCore` owns portable observations, geometry, the action registry, bilingual input routing, Jev request/response validation, and the bounded goal loop. `MacVoice` owns SwiftUI lifecycle, Keychain, permissions, microphone/FluidAudio, ScreenCaptureKit, AX proxies, and CGEvents. Native APIs remain behind injectable perception/decision/execution protocols so tests drive the actual loop with a simulated desktop. No shell tool, AppleScript evaluator, localhost service, or model-generated code is exposed.

```
Microphone → local utterance segmentation → Parakeet Ultra → wake/intent routing
                                                            ↓
GUI Start/Stop → cancellation generation → observe → Jev → validate → execute
                                            ↑                          ↓
                                            └──── fresh observation ────┘
```

## State and questions

Each observation has a UUID, monotonic acquisition time, app/PID, window frame, display-global point crop, image geometry, JPEG, a compact visual signature, focused field identity, and bounded AX controls. AX metadata is explicitly named `supplementary_accessibility`; absence never proves an object is absent. Secure fields are removed before serialization and their pixel regions redacted. Screenshot consent explains that other sensitive material can still appear visually.

The request retains the observation UUID, and action decoding refuses another observation even if it reuses the same AX IDs. Visual clicks additionally compare a 64 × 64 color-pixel patch around the proposed point in the old and fresh JPEG; a global thumbnail alone can hide a changed small icon. This reduces one specific stale-target risk, without proving that the model selected the correct control.

If AX provides no window, window-server metadata supplies the foreground process's top normal visible window. Full-display screenshots remain available with an explicitly incomplete, empty AX context. The fallback rechecks PID, window ID, frame and topmost window at a proposed visual click; unrelated windows and replacement dialogs invalidate it. It never manufactures a focused field, so typing remains unavailable until AX identifies one. Window titles are not read. Metadata enumeration runs only for this fallback, not on every normal AX observation.

Each Jev decision receives the original goal, optional correction, up to six action/outcome records, current screenshot, and dynamic candidates. The network client resolves the operation family first, then asks only its arguments with selected_operation in state. App catalogs are not truncated to 40 entries. AX traversal has node/time/depth budgets and reports truncation; targets are not cut off after 60 entries. Text choices come only from the user's verbatim transcript, quoted spans, and deterministic URL/search normalization. No model invents arbitrary text or executable commands. A separate Noul judges completion, another checks presence of the visual target, and another assesses sensitivity. Box locates the conditional next visual target independently; its answer is used only for a visual-click operation.

Initial gates: selected probability ≥0.75 and confidence ≥0.65; completion ≥0.95 with operation `done`; visual presence ≥0.95 and Box confidence ≥0.85. These are conservative policy defaults, not calibrated accuracy claims. Validate probability domains, sums, offered IDs, chosen argmax, image limits, finite positive geometry, and pinned model identity. Reject incompatible/missing outputs rather than guessing.

## Loop and execution

One goal, at most 20 decisions / 90 seconds, no generated subgoal list. Observe → decide → check generation → freshness → confirmation if needed → execute → observe. Record only observed effects; changed pixels do not prove success. Application launch has a native foreground-PID postcondition. Exact input commands finish after the requested input is posted. Other tasks use a fresh model judgment on observed state; uncertain Jev completion can escalate to the screen-enabled helper. Same-screen repeated actions, three consecutive no-change actions, and repeated waiting stop with a useful message. Transient HTTP retries are bounded and cancellation aware; no action replay on API failure.

All decisions are scoped to one observation. Visual targets may belong to another application on the captured display; freshness and secure-target checks still apply. Before input, recheck app, focused window/frame, secure-input state, target identity and geometry. For visual input re-capture and compare the scene; reject changed targets. Coordinates use top-left Core Graphics global points, not AppKit bottom-left points. Normalized boxes first map through image padding/content and crop to desktop points, including negative secondary-display origins. AXPress is preferred; mouse events require a valid point and hit test. Typing requires a live non-secure focused field and inserts verbatim Unicode without clipboard replacement. Common shortcuts use an enum; general key combinations use validated key names and modifiers. Pointer gestures support right/double clicks, dragging and movement.

Stop synchronously invalidates the generation and cancels the task before returning to the UI. Every action path checks cancellation immediately before posting/AX calls. Already posted OS input cannot be recalled. Final local stop/cancel utterances and a partial stop monitor can also cancel. Corrections invalidate old decisions and use a new observation; historical IDs are never reused as targets.

## Confirmation and privacy

Potentially sensitive operations pause for explicit confirmation tied to action, observation, generation, and a short expiry. New commands, Stop, target changes, and timeout invalidate it. Return/submission, unknown visual clicks, and actions labelled send/delete/share/pay require confirmation even if Jev says safe. Model sensitivity can add confirmation, never remove deterministic requirements. No automatic retry after a confirmed action. User can say “confirm / bevestig” or “cancel / annuleer”.

Confirmations carry an opaque UUID and monotonic deadline. The shared `ContinuousClock` time base advances during system sleep, and the workspace sleep notification stops listening until the user starts again. Approval callbacks must present that UUID, and authority is checked when approving and immediately before input, including after fresh capture. A cleanup timer cannot extend the deadline. Cancelling a task resumes pending confirmation rather than leaving a suspended continuation. Whole-goal deadlines are also checked after suspension and before action execution.

API key lives in Keychain. Audio remains local. Screenshots and AX metadata go to TypeSafe only after GUI consent. No content/screenshot persistence by default; diagnostics store stage timings, token counts, and estimated cost in memory. Opt-in debug logging persists compressed utterances, complete ASR results, model wire payloads, observations, and actions in bounded ZIPs; see [debug logging](debug-logging.md). FluidAudio console logging stays disabled; the app records its exposed result object and lifecycle directly. Secure AX regions are masked before compression; unavailable security metadata fails closed for typing. Redaction cannot guarantee removal of arbitrary secrets displayed in ordinary text or images.

## Speech and usability

Apple Silicon and macOS 14.2+. SwiftUI window and menu bar share one session model. First-run setup covers key, privacy consent, permissions, and a cancellable/retryable GUI model download with progress. FluidAudio is pinned, Ultra is selected explicitly, and assets are cached outside the bundle. No runtime terminal requirement.

Commands require a leading “Hey Jev” (including the observed “Hey Jeff” recognition variant). Dutch and English stop/cancel and confirmation phrases work without wake phrase when relevant. Ordinary speech is discarded. Explicit “dictate / dicteer” mode treats following text only as insertion; words such as “delete” inside dictation are never executed. In-flight command handling is single-session: corrections replace the goal; unrelated new commands cancel the previous goal before beginning.

Wake-free corrections apply only during a task or within 15 seconds of its last completion/failure. Stop and dictation clear correction authority. The original goal and latest correction are bounded separately; repeated corrections do not recursively grow old prompts. Audio chunks have sequence numbers; a gap stops recognition rather than allowing an incomplete utterance to execute. Speech older than five seconds at ASR entry or completion is rejected. The five-second cutoff is a conservative policy, not a measured performance claim. Microphone conversion/length errors produce visible recovery guidance.

## Explicit limits

This is an experimental visual assistant. Jev vision is experimental; ASR code-switching accuracy, dense UI localization, live Chrome behavior, and permission recovery need manual tests. No substantial text generation, optional Codex integration, automatic OCR, or automatic visual zoom refinement in the first release. App-launch selection searches the complete installed-app catalog, including Office short-name aliases. Clipboard, shell execution, unattended sensitive actions, and background capture while stopped are not supported.

See testing.md for reproducible validation and release.md for distribution status and credential setup.
