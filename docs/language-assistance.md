# Language assistance and central execution

Local Parakeet transcription and TypeSafe Jev remain the primary path. The optional OpenAI helper supplies text or one next-action proposal. It never receives shell, filesystem, MCP, background-job, or computer-use tools. Mac Voice Control remains the only executor. This is an experimental integration; real account and desktop acceptance are separate from automated tests.

## Setup

Authentication can use either **ChatGPT OAuth** or an **OpenAI API key**, selected in Setup. API keys are stored in a separate Keychain entry and can be replaced or removed. API-key requests do not require a ChatGPT connection and are billed to the OpenAI API account, separately from ChatGPT subscriptions. Enter an API-accessible model ID when using a key. Both methods use the same proposal schema, executor, and cancellation checks.

Voice modes are Wake phrase, Continuous commands, and Push to talk. Continuous mode removes the wake phrase requirement; Stop ends the session. Hold Control–Option–Space for a sentence and release to submit. Pauses during a hold do not submit partial instructions. Empty holds do nothing; holds reaching 15 seconds are rejected. Command–Option–Space toggles continuous commands, and Control–Option–Period stops. Global shortcuts use registered macOS hotkeys; a conflict is reported in status. Touch Bar continuous/Stop buttons are available when this app is active, rather than a persistent system Control Strip item.

1. In Setup, Continue with ChatGPT and authorize plan usage. Identity sign-in alone is insufficient.
2. Refresh available models and choose one. The initial preference is `gpt-6-luna`; the account-specific catalog determines available choices.
3. Enable language assistance. Separately enable screen context for requests about visible email, documents, or controls. Changing these settings stops the current session.
4. Start listening. A floating nonactivating panel displays transcript, processing status, confirmation preview when needed, and Stop. Runtime feedback does not activate the main window. Setup remains explicitly accessible from the menu bar.

The speech model reloads automatically after a successful load in this version, without automatically enabling the microphone. First-time downloads and retries remain explicit.

## Controller contract

- Writing/rewriting/translation requests prepare a single bounded text payload, then capture a fresh screen before Jev chooses the destination. Explicit dictate/dicteer bypasses the LLM and preserves the spoken payload.
- Jev's text choices include prepared text, marked as insertion data in the request. Its operation choices include `requestLanguage` only while a helper is available and below the call limit. Typed low-confidence decisions and explicit clarification can invoke assistance; malformed responses, authorization failures, and HTTP failures do not silently escalate.
- `LanguageReply` is bound to a request UUID and observation UUID. It contains text, one action, or clarification. Literal text must occur in the command or its deterministically recognized URLs; generated prose requires an explicit writing request.
- Action proposals map onto the existing `Action` registry. Targets must be observed and nonsecure; app IDs must be installed and respect explicitly named apps. Typing first focuses the target when necessary. URLs must be user-supplied. With screen context enabled, the helper can propose visual pointer gestures in global desktop points and assess completion against observed action history. Submission, close-tab, general key combinations and helper clicks retain confirmation requirements; recognized address-bar Enter is navigation; opening an application does not require helper confirmation.
- Both providers use the same foreground/window/focus checks, deadline, repetition bounds, confirmation mechanism, and native executor. At most three helper calls occur per goal. Each action is followed by observation; there is no blind batch execution.
- Stop invalidates the local generation before cancelling the run. Cancellation and deadline checks run after network responses and immediately before execution. Late replies cannot resume a cancelled task. Quit and system sleep stop execution. Already delivered OS events cannot be recalled.

## OpenAI connection

The native client implements the documented open-source **Sign in with ChatGPT** flow under its own name, Mac Voice Control. It does not read or reuse Codex credentials. Authorization uses a loopback listener bound to `127.0.0.1`, fresh state/nonce, S256 PKCE, and a persisted opaque host ID. ID-token signatures are checked against OpenAI JWKS (RS256 or ES256), then issuer, audience, expiry, nonce, and returning-account identity are validated. Tokens and rotating refresh credentials are kept in Keychain; refreshes are serialized. Disconnect clears local tokens and attempts renewable-session revocation. An unconfirmed remote revocation is reported.

Responses requests use the public endpoint, `store:false`, `stream:true`, bounded context, and a strict proposal schema. Only `response.completed` with a valid bound proposal can reach the executor; streamed deltas, incomplete responses, refusals, malformed JSON, and interrupted streams cannot. HTTP redirects are rejected. No credentials, screenshots, transcripts, or response bodies are logged. Displayed token/cost metrics are TypeSafe-only; ChatGPT usage is managed in ChatGPT Settings.

## Validation

Portable tests cover payload fidelity, generated-text candidates, explicit screen context, schema requests, terminal stream handling, invented targets/apps/URLs, forbidden operations, request/observation binding, stale actions, helper call bounds, and Stop before/during assistance. OAuth tests cover callback binding, duplicate parameters, identity claims, and form encoding. The existing macOS CI workflow compiles the actual SwiftUI application and runs native tests, including new RSA and ECDSA identity-signature fixtures. A successful run for this change is still required; native syntax checks alone do not establish a successful macOS build.

Real-account sign-in, refresh, revoked consent, unavailable models/plan limits, live Jev decisions, and actual Dutch/English voice workflows must be verified on a Mac. In particular check Stage Manager focus, overlay interaction and placement on multiple displays, and that stopping during a delayed model response produces no subsequent input. No live end-to-end accuracy or latency claim is made by mocked tests.

Official references checked 27 October 2026:

- https://developers.openai.com/siwc/token-sharing-open-source/sign-in
- https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference
- https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations
- https://developers.openai.com/api/docs/guides/structured-outputs
