# Source-informed design notes — 30 October 2026

Source was read before implementation, rather than extrapolating from demonstrations. References below were inspected at upstream HEAD on this date. All four repositories declare MIT licenses. The new adapter/planner implementation was written here; no upstream code was copied into the application and their benchmark figures are not reported as our performance.

| Reference | Files inspected | Adopted pattern / boundary |
|---|---|---|
| [Jev Ultrafast](https://github.com/browser-use/jev-ultrafast) | `agent.py`, `browser.py`, `model.py`, `questions.py`, `snapshot.js`, `docs/performance.md`, LICENSE | Compact indexed semantics; speculative operation/target heads consumed conditionally; private stable node references; target-specific checks; cached writing; observed completion. Its loop makes multiple decisions. Its CDP/browser-harness transport and reported timings were not transplanted. |
| [TypeSafe Computer Use](https://github.com/awlevin/typesafe-computer-use) | `docs/browser-backend.md`, `docs/how-a-step-works.md`, `browser/act.py`, LICENSE | Browser semantics alongside native AX/vision; exclude field values; separate dispatch from effects; bounded read-only recovery. OCR remains deferred here. |
| [Atticus](https://github.com/SaarthurR/atticus-mac) | `atticus.py` fast-command and workflow sections, `Atticus.swift`, LICENSE | Deterministic routing before models; verified dependent steps; preserve contextual commands. Shell/AppleScript tools and workflow replay were not added. |
| [Pace](https://github.com/HeyPace/pace) | `docs/architecture/computer-use-runtime.md`, planning/latency and audio-pipeline learning notes, LICENSE | Native semantic dispatch; session resources; state-based settling; bounded transactions. The architecture document itself distinguishes present functionality from future phases; we did not treat its roadmap as validated implementation evidence. |

Chrome integration was chosen separately: a permission-scoped development extension and Native Messaging host fit a normal native Mac app better than enabling remote debugging on a user's profile. The initial transport uses a private mailbox with a documented polling cost. A faster socket transport should follow measured Mac evidence, rather than an untested browser-demo latency claim.

The first working slice intentionally leaves structural replanning, OCR, learned workflows and new model-backed field extraction for later. It improves routing, objective tracking, semantics, grounding and validation without replacing local ASR, Jev, existing authentication, visual geometry, consent identities, cancellation or the native executor.
