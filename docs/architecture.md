# Architecture

## Execution flow

Local microphone endpointing → Parakeet Ultra final transcript → `InputRouter` (wake phrase, Stop, confirmation, correction, dictation) → `CommandRouter` → optional `TaskPlanner` → observe → Jev → validate → execute → observe and verify.

`VoiceCore` contains the portable policy and loop. `MacVoice` owns AppKit/SwiftUI, FluidAudio, TCC, AX references, screenshots and CGEvents. `MacVoiceBrowserHost` is a small framed Native Messaging executable. `BrowserExtension` contains fixed, isolated-world browser code. No model has a shell, JavaScript evaluator, or arbitrary selector interface.

## Local routing

`CommandRouter.swift` parses whole commands, including Dutch/English combinations, against the installed application catalog. Known app launches, Downloads, explicit web addresses, tab commands, back/forward, scrolling and safe focused literal insertion bypass Jev. Only a known browser launch followed by an explicit URL can form a two-action direct batch. The launch must be verified before the dependent navigation begins. Additional or uncertain clauses preserve the full goal for the agent.

Literal dictation remains literal, including words like “delete”. Quoted typing strips only a recognized field suffix; named or uncertain destinations go through grounded target selection. Direct closing of tabs still uses the loop's confirmation identity, expiry and freshness gates, without a Jev call.

`DirectCommandExecuting` returns `DirectResult`. Foreground app activation and supported query-free browser URL identity can be verified. Dispatch of a native shortcut, scrolling, Downloads or text insertion is reported as **sent, outcome unverified**, rather than a completed task. This is intentionally weaker evidence than verified goal completion.

## Plans and text

`TaskPlan.swift` defines `TaskPlan`, `TaskStep`, `TaskState`, `TaskPlanner`, `TaskProgressTracker`, and `TaskCompletionVerifier`. The deterministic planner runs once per new command, splits bounded action clauses outside quotations, recognizes installed apps and explicit URLs, and derives bounded search terms. Unknown clauses retain their original text as generic objectives. It does not invent UI objects or paths through a website.

Jev receives both the full authoritative goal and the current objective/success condition. A high-confidence independent completion answer and a fresh observation are required before advancing. Known objectives have extra deterministic checks: foreground app, observed destination, relevant content after interaction, or a dated result's verified destination. A failed objective becomes blocked. Corrections cancel the previous run and construct a new plan using bounded conversation history.

`TextIntent.swift` records literal, derived-query and validated-language provenance in real decision candidates. Derived queries are limited to observed search fields. Prepared writing is cached within the run; it is not regenerated after an unrelated screen update. Existing `LanguageHelping` remains optional and retains request/observation identity checks. Transformation and form-value intent names are reserved; there is no new general field-value extraction model or model-backed planner in this slice.

The planner does **not** implement autonomous structural replanning. Stale observations are reacquired, but impossible or ambiguous objectives stop. General natural language and unfamiliar compound grammar still depend on Jev and optional language assistance.

## Hybrid perception and decisions

`Observation` includes a `PerceptionSource`: browser, accessibility, or visual. `Control` adds checked/selected state, bounded options, nearby public context, visible ISO date and sanitized link destinations. Input values are not model state.

`MacDesktop.observe(preference:)` prefers the opt-in Chrome connection, then AX controls. An image is captured when semantics are unavailable, or after Jev selects `requestVision`. A semantic-only preference supports direct actions and dictation without capturing an image even when the AX tree is empty. AX IPC stays on its bounded worker queue.

`JevRequest.Mode.structured` sends no image asset, image header, Box or visual-presence question. Operations/target heads are filtered to available controls, explicit URLs, relevant apps, text and dropdowns. Only the selected operation's target heads are consumed. `visual` preserves the existing referenced JPEG, presence, Box, probability, confidence, geometry and model-version validation. Jev stays pinned to `jev-1.14.0`.

Native semantic freshness checks use app/window identity and live AX element label, frame, enabled state, selected/checked state and typing focus. Untargeted actions/completion compare fresh semantic state. A focused field's bounded value is retained privately for freshness, never serialized into observations or debug payloads; selected text is not silently replaced. Visual clicks retain fresh capture, local pixel-patch comparison, occlusion and coordinate guards.

Semantic scene comparison ignores unrelated browser revision increments, so an animation does not automatically defeat the repeat-action guard. Document/tab identity and target-specific guards remain mandatory. Browser guards include values and caret state **only inside the isolated world**, not in model requests.

## Chrome integration

See [browser setup and security](browser-integration.md). The opt-in Manifest V3 extension uses Native Messaging, `activeTab`, and site access granted by the user. No debugging port is exposed. One persistent native port connects to the bundled Swift host. A private mailbox relays finite typed messages between the host and app, using 20ms polling in each direction. This trades a small local latency floor for portable, inspectable IPC without a listener or model-driven process execution.

Messages carry UUIDs, connection/run IDs and a three-second expiry. The native host is restricted to the bundled extension origin. It atomically claims each message once and does not dispatch messages addressed to an earlier host instance. Chrome rechecks active foreground tab, document identity, node identity, metadata, visibility, disabled/read-only state, focus, caret/value state and hit testing. Observed node IDs stay in the isolated world; the model cannot construct selectors or code. Page text remains untrusted evidence.

The general adapter supports observation, links/buttons, focus, bounded insertion, native selects, scrolling, explicit navigation and selected tab/history operations. Unknown buttons, selections, Enter, tab closing and consequential labels require confirmation; recognized navigation links and search controls can proceed without it. A model can increase risk, never remove the deterministic floor.

Unsupported editors, shadow roots, iframes, canvas or browser chrome fall back during **observation**. A failed mutation does not automatically try another backend. Navigation can destroy an execution context; uncertain acknowledgements stop rather than replaying a click.

Newest selection compares **visible** matching links only. All matches must have valid, unambiguous visible ISO dates and query/fragment-free destinations, with one unique maximum. Missing/tied dates and opaque/query-bearing result identity stop. This does not establish the newest item across pagination or unseen records. Query/fragment-bearing explicit navigation is allowed, but sanitized URL observations cannot prove its full identity.

## Bounds, cancellation and verification

The existing 20-decision/90-second limits, action fingerprints, no-change/wait bounds, confirmation UUIDs, monotonic expiry and cancellation generation remain. Stop cancels browser authority and invalidates native transactions/references. Every native dispatch rechecks cancellation; typing checks focus and insertion range between chunks. Already delegated browser operations and posted OS input cannot be recalled.

`MacDesktop.waitForChange` observes immediately and polls within a short bound when necessary, caching the result for the next decision. The unconditional 180ms startup and 220/750ms loop sleeps are removed from the application path. The portable protocol's fallback wait is a small fixture/compatibility delay; the native implementation uses state changes. The existing 800ms speech endpoint remains unchanged because no microphone accuracy/latency evidence justified tuning it.

## Metrics and privacy

`CommandMetrics` records content-free timing/count aggregates and verified/dispatched/failed/cancelled outcome. `GoalLoop.onMetrics` exposes them to `AppModel`; `SessionEvent` continues to feed the overlay and existing opt-in debug infrastructure. Timing boundaries include routing, planning, Jev, language assistance, freshness, execution, waiting, first action and wall-clock completion. Screenshot acquisition/encoding are split in native capture; native capture counts include freshness and wait captures. Counts include requests/bytes/tokens, actions, confirmations, stale rejections and images sent. No token estimates are substituted for missing provider usage.

Wall-clock completion is measured directly, never by summing stage timers. Some diagnostic stages contain suboperations (freshness may capture, execution may await a browser acknowledgement); their timers are nested diagnostics and must not be summed as independent elapsed time. There is no measured replan count, exact HTTP-retry total, language-provider token cost, or speech-to-task benchmark yet. TypeSafe estimated cost remains the pre-existing input-token estimate.

Metrics contain no transcripts, labels, URLs or images. Debug logging stays off by default. Browser IPC contains bounded task data in a user-owned 0700 directory with 0600 files; messages are consumed/deleted and crash remnants are cleaned on the host's next run. This is temporary IPC, not a debug archive. As before, visible public text and images can contain private information despite secure-field exclusions. No raw audio is transmitted.

## Remaining product work

Real Apple Silicon compilation, TCC/Native Messaging installation, spoken Stop races, microphone code-switching, live Jev decisions and real desktop acceptance remain required. There is no OCR backend, learned workflow store, autonomous replanning, comprehensive text replacement, or spoken feedback implementation in this slice. Existing local speech, language authentication, confirmation UI, overlay, visual geometry and credential storage remain in place.
