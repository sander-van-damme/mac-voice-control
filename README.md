# Mac Voice Control

A native macOS assistant for Dutch, English, and mixed spoken computer commands. Local Parakeet Ultra transcribes your voice; TypeSafe Jev 1.14 chooses the next supported action using a current screenshot and supplementary Accessibility information. Optional ChatGPT language assistance prepares text and proposes difficult next steps. Every computer action is executed and checked by this application.

**Experimental development software.** Jev's image/Box API is experimental. Compilation and automated policy tests do not establish reliable desktop control or mixed-language recognition. See [validation status](docs/testing.md) before using it with important work.

## Requirements

- An **Apple Silicon Mac** running **macOS 14.2 or later**. Intel builds are not provided.
- A TypeSafe API key and an internet connection for decisions.
- Roughly 1 GB of disk space for the local speech model; initial download requires internet. Actual footprint and memory vary by model revision.
- Microphone, Accessibility, and Screen Recording permissions.

## Download and install — no terminal needed

1. Open [GitHub Actions](https://github.com/sander-van-damme/mac-voice-control/actions/workflows/ci.yml), choose a successful **Build and test** run, and download **Mac-Voice-Control-arm64-development** from its Artifacts section. GitHub requires you to sign in to download Actions artifacts.
2. Unzip the download and open the `.dmg`.
3. Drag **Mac Voice Control** to **Applications**, then open it from Applications.
4. Development artifacts are ad-hoc signed and **not notarized by Apple**. macOS may block the first launch. For a build you trust, use **System Settings → Privacy & Security → Open Anyway** after the blocked launch. Do not disable Gatekeeper globally. Some managed Macs do not permit unsigned development apps.
5. Future public builds are available from [Releases](https://github.com/sander-van-damme/mac-voice-control/releases). Only a filename ending in **notarized.dmg** denotes a signed and notarized build. A `developer-id` build is signed but not notarized; `development-unsigned` is an ad-hoc development build.

No speech models are included in the repository or DMG. Do not mistake a source ZIP for the installable application.

## First-run setup

1. Obtain a key at the [TypeSafe console](https://console.typesafe.ai/) and save it in Setup. It is stored in this Mac's Keychain.
2. Read and enable **Allow screen context to be sent to TypeSafe**. Screenshots may include visible private documents even after known password fields are masked. Audio stays on the Mac.
3. Use the permission buttons. In Privacy & Security, enable this installed copy of the app for Accessibility and Screen Recording. Allow Microphone access. **Quit and reopen after granting Screen Recording**, then refresh permissions. Replacing an unsigned build can require granting permissions again.
4. Select **Download / load local speech model**. The GUI shows file progress and model preparation. If it fails, retry; completed files are cached. Ultra's encoder alone is approximately 595 MB. Preparing Core ML assets can take longer than downloading the final file.
5. Optionally enable **faster spoken stop**. This uses Apple's on-device English recognizer when supported; it never falls back to Apple's servers. Main local recognition also handles Dutch/English cancellation.

After the first successful model load in this version, subsequent launches automatically prepare the cached model. This does not start microphone listening. On first use or after an unsuccessful preparation, use **Download / load** to retry; cached files are reused.

### Optional ChatGPT language assistance

Setup offers **ChatGPT OAuth** or **OpenAI API key** authentication. To use an API key, select that option, save the key in Keychain, enter an API-accessible model ID, and enable language assistance. No OAuth connection is needed for API-key mode. API usage is billed separately from a ChatGPT subscription.

In Setup, choose **Continue with ChatGPT**, complete browser sign-in, and authorize ChatGPT plan usage. Select an available model and enable **Use ChatGPT for language assistance**. GPT-6 Luna is the initial preference; model access depends on your account. No Codex CLI, OpenAI API key, or local LLM download is required. If you decline plan usage, Jev and local speech remain available with language assistance off.

Commands and recent action outcomes go to OpenAI when assistance is needed. **Share screen context with ChatGPT** separately enables screenshot and bounded Accessibility context, needed for requests about visible content. Audio stays local. Requests use your ChatGPT plan limits. Credentials are stored in this Mac's Keychain. See [language assistance](docs/language-assistance.md) for behavior, cancellation, and validation limits.

## Use it

Choose a voice mode in Setup or the menu bar. **Continuous commands** accepts each spoken command without a wake phrase until stopped. **Push to talk** captures a full sentence while **Control–Option–Space** is held, including pauses, then submits it on release. **Command–Option–Space** toggles continuous commands, and **Control–Option–Period** stops immediately. These global shortcuts work while other apps are active. Touch Bar buttons for continuous commands and Stop appear while Mac Voice Control is active; they do not install a global Control Strip item.

In **Wake phrase** mode, click **Start listening** and begin each command with **Hey Jev** (or **Hey Jeff**). The control window hides; a nonactivating overlay shows transcript, status, confirmations, and **Stop**. Push-to-talk and continuous commands use the same local transcription and guarded execution as wake-phrase mode.

- “Hey Jev, open Chrome.”
- “Hey Jev, open een nieuw tabblad en ga naar GitHub.”
- “Hey Jev, scroll down a little.”
- “Hey Jev, klik op de groene knop rechtsboven.”
- “Hey Jev, open Finder en ga naar mijn downloads.”
- “Hey Jev, type 'Hello, hoe gaat het?' in het tekstveld.”

Keep commands under 15 seconds and pause at the end. Missing audio chunks, overly long utterances, and transcripts delayed by more than five seconds cause a visible stop; restart and repeat the full command. Ordinary speech without the wake phrase is ignored. Dutch/English code-switching is supported by the selected multilingual provider but **has not been validated on a real microphone corpus in this development environment**. Use the checklist in [testing.md](docs/testing.md) to evaluate your accent and microphone.

Say **stop**, **stop nu**, **cancel**, or **annuleer** to stop, or use **Stop** in the menu bar or control window. The button cancels pending decisions and stops listening. Already posted OS input cannot be recalled. Spoken stop has recognition latency; use the button if immediate cancellation matters. System sleep stops the session; click Start again after waking.

During a task or within 15 seconds afterward, correct it with **“Nee, de andere”**, **“Actually, go back”**, or **“No, I meant Chrome”**. After that window, give the full command with **Hey Jev**. This cancels the previous run and observes the current screen again. It does not automatically undo arbitrary changes.

For literal insertion, focus a text field and say **“Hey Jev, dicteer …”** or **“Hey Jev, dictate …”**. The remainder is treated as text, never as another computer command, and bypasses the language helper. Typing inserts at the cursor; it does not silently clear existing contents. With ChatGPT assistance enabled, requests such as **“Hey Jev, write a short greeting in Dutch in this field”** prepare text for Jev to insert. Each insertion is limited to 2,000 UTF-16 units. Newlines, tabs, and control characters are refused; request Enter separately and confirm it.

Sensitive actions pause and show the proposed action. Say **confirm / bevestig** or use the Confirm button. **Cancel / annuleer**, another command, a changed target, Stop, or 25 seconds of inactivity invalidates confirmation. Visual clicks, Enter/submission, and closing tabs always require confirmation. The app stops when uncertainty, repeated actions, or execution limits prevent safe progress.

## Privacy and limitations

- Voice audio is processed locally. Transcripts, screenshots, and bounded AX context go to TypeSafe during ordinary decisions. Optional language assistance sends commands and recent action outcomes to OpenAI; screenshots and AX controls require its separate screen-context setting. Explicit dictation inserts locally.
- Screenshots and private document content are not saved to persistent logs. Keychain stores the API key; preferences store consent. Local model files are cached by FluidAudio. Diagnostics show only timings, token usage, and estimated direct API cost; transcript feedback stays in memory.
- Known secure AX fields are masked, secure focus blocks control, unknown text focus blocks typing, and secure values are never read as labels. **This does not guarantee that screenshots contain no private material.** Canvas text, ordinary fields, inaccessible controls, and a truncated AX tree can hide secrets from redaction. Keep sensitive windows out of view.
- The app controls the foreground window on the display with the largest overlap. A window spanning displays is cropped to one display; offscreen controls require scrolling or moving the window. Moving/resizing/switching windows during a decision causes re-observation or a safe stop.
- Chrome's AX tree is incomplete on some sites, dense tab strips, canvas apps, rich editors, and loading pages. Vision remains first-class. Google Docs, Gmail, Miro, and actual Chrome end-to-end flows still need manual validation.
- Automatic OCR, target zoom refinement, background-window control, Intel support, and configurable shortcut bindings are later milestones. No shell or arbitrary code execution is exposed to either model.
- Confidence gates and safety classification reduce risk but do not establish correctness. This is supervised experimental software.

## Troubleshooting

| Symptom | What to do |
|---|---|
| Missing permissions / black capture | Enable the installed copy in Privacy & Security, quit/reopen, and Refresh permissions. |
| No target window / unknown secure focus | Open a normal application window and focus a non-password control. |
| TypeSafe rejects key | Replace the key in Setup and check your TypeSafe account. |
| TypeSafe rejects image/model | API is experimental. Check model/API compatibility; no automatic downgrade occurs. |
| Speech model fails to load | Retry from Setup after checking network and free space. The downloader checks/reuses cached files. |
| Wrong or missed transcript | Speak a shorter command with a leading wake phrase; use Type a command to isolate speech from decision behavior. |
| Repeated/stale target warning | Wait for the page to settle, enlarge the window, and name the target more precisely. |
| Confirmation no longer applies | Repeat the command. Old approvals are never reused. |

## Developer build

Use Xcode **26.3** with Swift 6.2 on an Apple Silicon Mac. Open `Package.swift` in Xcode, or use the commands below. Tests mock Jev and do not download speech weights or need a paid API key.

```sh
swift package resolve
swift test --parallel
bash scripts/package.sh
open 'dist/Mac Voice Control.app'
```

Run the packaged app for microphone/TCC testing; running a bare SwiftPM executable is not the end-user launch path. The portable VoiceCore target also builds on Linux with Swift 6.2; native targets and FluidAudio are included only on macOS.

GitHub Actions builds, tests, and packages the same product into a DMG. See [release setup](docs/release.md) for optional Developer ID signing/notarization, [research](docs/research.md) and the [independent follow-up review](docs/research-follow-up.md) for sources and repository comparisons, [architecture](docs/architecture.md) for the action/observation contract, and [tests](docs/testing.md) for coverage and manual acceptance.

Source is MIT-licensed. Adapted source, FluidAudio, and downloaded model licensing are described in [third-party notices](THIRD_PARTY_NOTICES.md).
