# Testing and honest validation status

Development began on Linux on 26 October 2026. Native tests/builds run on GitHub-hosted Apple Silicon macOS runners. This document distinguishes executable checks from pending desktop acceptance.

## Automated checks

`swift test --parallel` runs the real VoiceCore module against synthetic Jev fixtures and a stateful fake desktop. No paid key, microphone, user screen, or model download is needed. Tests cover image request construction, explicit asset references/header model contract, response parsing, probability/choice validation, target presence, geometry and padding, negative display origins, Retina independence, candidate limits, secure normalization, bilingual routing, literal dictation, correction context, confirmation expiry, stale targets, cancellation after an in-flight decision, repeats, bounded waiting, independent completion evidence, and multi-step state transitions.

Synthetic fixtures are explicitly labelled. No live response corpus was supplied and none is fabricated. The fake world runs through GoalLoop itself; it is not a replacement loop in a test.

Build and release scripts validate bundle metadata, code signature integrity, and DMG integrity. Notarized builds additionally validate the staple and Gatekeeper assessment. A macOS CI runner does **not** verify TCC grants, real microphone recognition, correct clicks in Chrome, or a user's desktop behavior.

See the linked workflow run/PR for the actual result and artifact of a particular revision. Build outcomes are recorded in `docs/validation.md` after CI finishes.

## Optional live API smoke test

The `scripts/live-jev-smoke.py` script reads TYPESAFE_API_KEY from the environment and sends a generated, non-private image with simple Choice, Noul, and Box questions. It checks pinned model identity, response primitives, and image support, prints only timing/usage, and never controls the computer. This incurs API usage and is opt-in; it is not part of ordinary CI. The test checks protocol availability, not dense-screen pointing accuracy.

## Manual acceptance — real Mac required

Record OS/hardware/build SHA, screen layout/scaling, microphone, ASR model, language, transcript, visible outcome, false actions, and timing. Begin with disposable files and test accounts. A checked row needs observed evidence; compilation is insufficient.

| Scenario | Repeatable steps / acceptance | Status |
|---|---|---|
| Install / first run | Download DMG, drag to Applications, launch through Finder, save key, grant permissions, download model with progress. Relaunch and load from cache. | Not run |
| Native app opening/switching | From TextEdit say “Hey Jev, open Finder”, then “open Calculator”. Correct app should become frontmost. | Not run |
| Chrome website | With Chrome foreground, ask for GitHub. Confirm correct app/site and no unrelated tab/window closure. | Not run |
| AX labelled button | Use a local disposable HTML form, ask to focus Search and click Next. Confirm current node and observed outcome. | Not run |
| Visual icon | Use an icon-only button absent from AX. Confirm preview prompt and visible target location; absence must refuse. | Not run |
| Multi-step without planner | “Open Chrome, open a new tab, go to GitHub.” Observe each action and final completion, no generative API. | Not run |
| Dutch / English UI | Dutch instructions on English macOS/Chrome. Record transcript and action correctness separately. | Not run |
| English / Dutch UI | English instructions on Dutch macOS/Chrome. | Not run |
| Mixed speech | Use the corpus below, three repetitions each, accents/microphones recorded. | Not run |
| Dictation isolation | “Hey Jev, dictate delete all files” into TextEdit: only those words inserted. No deletion or submission. | Not run |
| Corrections | After a wrong disposable selection: “Nee, de andere”; then “No, I meant Chrome, not Safari”. Old requests cannot execute afterward. | Not run |
| Interrupt | Stop button during capture, network request, confirmation, and long Unicode typing. No later action starts; key/mouse up events are paired. Repeat with spoken stop and measure latency. | Not run |
| Loading / moving window | Trigger navigation; move/resize/change foreground while Jev decides. Reject old target, observe again, never click another app. | Not run |
| Incomplete AX | Test canvas and Google Docs/Gmail/GitHub/Miro independently. Record omissions; visual inference still receives screenshot. | Not run |
| Sensitive actions | Disposable Send/Delete/Share/Enter. Requires explicit, expiring confirmation. Cancel, unrelated command, and moved target invalidate consent. | Not run |
| Missing permissions/API failure | Revoke each permission; use invalid key; disconnect network. UI explains recovery, no blind action retry. | Not run |
| Multi-display / Retina | Place window on left/above secondary display, mixed scaling, move across displays, span displays. Box center must map to correct global points; clipping is documented. | Not run |
| Secure data | Inspect outgoing test requests with disposable dummy password fields; secure labels/values absent and known pixel regions black. Missing AX security metadata remains a documented privacy limitation. | Not run |
| Audio lifecycle | Silence for 5 minutes, unplug microphone, cancel model download, retry download, sleep/wake, quit during transcription. No queued stale commands execute. | Not run |

### Speech corpus

Use at least three speakers if possible. Start every command with Hey Jev; include background speech with no wake phrase as negative examples.

1. Open Chrome.
2. Open een nieuw tabblad en ga naar GitHub.
3. Klik op de groene knop rechtsboven.
4. Scroll down a little.
5. Open Finder en ga naar mijn downloads.
6. Search for HumanEyes and open the first result.
7. Go back to the previous tab.
8. Klik op die tweede optie.
9. Type “Hello, how are you?” in het tekstveld.
10. Open Chrome, ga naar GitHub en open de laatste pull request.
11. Dicteer “Please review dit document morgen”.
12. Nee, de andere. / Actually, go back. / No, I meant Chrome, not Safari.
13. Stop. / Stop nu. / Annuleer.
14. Background: “I told someone to open Chrome yesterday.” (must not act)

Compute ASR word error rate against manually transcribed audio, command success rate, false activation rate, and action accuracy independently. Do not use English WER as evidence of Dutch or code-switching quality. Record silence endpoint delay separately from inference time.

## Performance measurement

In-memory diagnostics expose `transcription_ms`, `accessibility_ms`, `capture_ms`, `jev_ms`, `action_ms`, and `command_to_first_action_ms`, plus returned input tokens and estimated cost at $0.042/M input tokens. `transcription_ms` starts when a completed utterance enters ASR; add approximately 800 ms endpoint silence to measure speech-end latency. Audio queueing, warm/cold load, and partial-stop latency require external measurement. Core ML may finish an already-running inference after Stop, but its result is discarded.

For a baseline, run 30 simple commands and 10 multi-step tasks, report p50/p95 stage and end-to-end times, successes/failures, warm/cold model state, and hardware. No actual application performance numbers are claimed before those measurements exist.

## Known gaps / release gate

Real speech quality, correct ScreenCaptureKit crop orientation on multiple displays, TCC recovery, keyboard layout variations, app-specific Accessibility semantics, and calibrated visual confidence thresholds remain release gates. Energy-based segmentation is a simple baseline, not learned VAD. Screen signature sampling can miss a small local change; live AX identity/focus guards help but do not prove visual target correctness. A production release needs a real desktop validation pass and signed/notarized artifacts.
