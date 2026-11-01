# Debug logging

In Setup, enable **Enable debug logging** before reproducing an issue. Choose **Open debug log folder** afterward to flush pending entries and seal the current ZIP. You can continue using the app: subsequent events go into a new ZIP. Disable logging when finished. The preference persists across launches and defaults to off.

The archives stay on your Mac. Upload selected ZIPs manually; opening the folder never uploads them. Logs intentionally contain voice and screen content, including ordinary speech that ASR transcribed but the wake-word router ignored. Share them only when you intend to share that content. Existing password-field masking and screen-sharing permissions still apply. Logging does not enable extra screenshots or extra microphone recording.

## Content and format

Each event has a UUID-named `.event.json` metadata entry and a payload entry referenced by its `payload` field. Metadata includes an ISO 8601 UTC timestamp with milliseconds, monotonic seconds, sequence, logging session ID, event kind, and available correlation IDs. Sort by timestamp and sequence; match `utterance_id`, `request_id`, `observation_id`, and goal `run_id` across files and parts. Sequences restart with the process. `logging.enabled` records format, app version, and OS. Every ZIP opens independently with standard unzip tools; all entries use lossless DEFLATE.

Captured content:

- Segmented utterances sent to Parakeet: mono 16 kHz AAC-LC at 24 kbit/s in standalone `.aac` ADTS files. Original float PCM is never written to disk. Silence outside utterances is omitted; this is not a continuous microphone recorder.
- Speech model preparation progress, transcription lifecycle, sample counts, audio discontinuities, and the complete Codable `ASRResult` exposed by FluidAudio: text, confidence, duration, processing time, token timings, performance metrics, and CTC metadata when present. Apple's optional on-device stop recognizer contributes partial/final text and errors. Dependency console logging stays disabled; internal tensors and model weights are not dumped.
- TypeSafe Jev: full serialized request bodies (including image data), full raw response bodies before decoding, status, each retry attempt, transport errors, and request/observation IDs. Unknown response fields are retained.
- ChatGPT language assistance: full request body and raw SSE data lines through the terminal response, including complete response objects, deltas, usage, and errors delivered on that stream. Partial streams survive cancellation/errors. Existing response size limits still apply. Authentication headers, Keychain data, tokens, and OAuth/sign-in responses are never passed to the logger.
- Desktop observations and JPEG screenshots, including screenshots used for freshness checks. Observations contain AX controls, geometry, focused control, timings, and scene signature. Request bodies also retain the exact submitted image.
- Routed input, goals, proposed actions, confirmation decisions, session phases, timings, token/cost counters, action starts and completion status, final observed action history, and application errors. `action.finished.completed` means the native operation returned successfully; visible success is evaluated separately by subsequent observations/history.

Images retain the app's existing compressed JPEG representation so visual issues can be investigated against exactly what the model saw. Only audio is additionally lossy-compressed.

## Storage and limits

Location: `~/Library/Caches/MacVoiceControl/DebugLogs/`.

- Each `debug-*.zip` is at most **25,000,000 bytes**, including ZIP headers and the central directory. Rotation happens before adding an event that would cross the limit; metadata and its payload stay together. Parts also rotate after 10,000 ZIP entries to bound directory overhead.
- The managed cache stays at or below **1,000,000,000 bytes**. Oldest parts are deleted before a write needs space. The active part counts toward this total. Unrelated files in this directory are not managed; do not store other files there. macOS may reclaim cache files.
- Directory permissions are owner-only (`0700`); ZIP permissions are owner read/write (`0600`). ZIPs are not encrypted.
- Compression and disk writes run on a serial utility worker. Admission is bounded to 32 MB of estimated retained payload/metadata memory and 256 queued events, with a 16 MB per-payload guard. Under overload, events are dropped; the next admitted event reports `dropped_before`. This keeps diagnostics from exhausting memory or blocking desktop control indefinitely.
- Disabling invalidates queued events and waits for an already-running write to finish. Existing archives remain available. Normal shutdown flushes the queue. Opening the folder seals the active archive so the app does not modify it afterward.
- A disk/encoding error skips the affected event and is reported when opening the folder. The logger does not stop desktop control. Following an abrupt process/disk interruption, startup removes a managed ZIP missing its final end-of-central-directory marker. Older completed parts remain. This is best-effort diagnostic logging, not a crash-safe audit journal.

## Upload-limit research

Checked 27 October 2026:

- OpenAI's [File Uploads FAQ](https://help.openai.com/en/articles/8555545-file-uploads-faq) documents a 512 MB maximum for ChatGPT documents/presentations and audio, plus separate content-specific limits.
- [Using Codex with your ChatGPT plan](https://help.openai.com/en/articles/11369540-using-codex-with-your-chatgpt-plan) distinguishes ChatGPT upload usage limits from Codex usage limits. It does not specify a Codex ZIP attachment byte limit.

A Codex-specific ZIP maximum could not be verified from those public documents. The **25 MB** part size is a conservative engineering default, not a claim about Codex's maximum or ZIP support on every client. It deliberately leaves substantial headroom below the documented ChatGPT file-size ceiling. Adjust `DebugLog.archiveLimit` if the target client's documented limit changes. ZIP size alone does not guarantee a whole archive can be analyzed in one context; upload relevant parts first.

## Validation

Portable tests independently parse ZIP structures, decompress payloads, validate CRCs, and check opt-in behavior, rotation, retention, restart handling, overload reporting, sealing for sharing, and IO errors. The macOS test target includes an AAC round-trip test. Run `swift test --parallel` on an Apple Silicon Mac to compile the actual app and exercise AVFoundation.

Manual check on macOS: enable logging, load speech, speak a command, exercise Jev and optional ChatGPT, confirm/cancel an action, and open the folder. Unzip a part and play an AAC snippet; correlate full ASR results and model objects with screenshots/actions. Disable and confirm the files stop changing. Test quit/relaunch and the same-folder Finder button with logging disabled.


## Semantic-agent diagnostics

`CommandMetrics` aggregates are separate from sensitive debug payloads and do not enable logging. Structured Jev payloads contain no image assets; visual requests and screenshots retain the existing opt-in archive policy. Browser observations may contain private visible text despite field-value exclusions. Native focused-field freshness values and browser value/caret guard data remain private in memory and are not serialized into observations.

The browser mailbox is temporary, permission-restricted IPC rather than a diagnostic archive. It can briefly contain task instructions, text to insert and public page observations. Messages are deleted after consumption; crash remnants are removed on the next host run. Do not include the mailbox in log uploads. Performance stage timers can nest; use measured `task_completion_ms`, rather than adding all timers, for total latency.
