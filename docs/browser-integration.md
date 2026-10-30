# Chrome semantic control

This is an opt-in development extension, not a published Chrome Web Store package.

## Install without terminal commands

1. Install the packaged Mac Voice Control app in Applications. Development `swift run` does not bundle the host/extension.
2. In Setup, press **Set up Chrome extension**. This registers the bundled host in your user Chrome NativeMessagingHosts directory and opens the supplied extension folder.
3. Open `chrome://extensions`, enable Developer mode, choose **Load unpacked**, and select that extension folder.
4. On a site you want controlled, open the extension popup and press **Allow this site**, then **Reconnect to app** if necessary.
5. Enable **Use Chrome semantic browser control** in app Setup. Start listening again after changing this setting.

The stable development extension ID is `jmfolbhhccnileefopndlkjokamifggp`. The manifest's public key preserves this ID across local installations. No signing private key is distributed. Managed Chrome policies can prohibit unpacked extensions; in that case use Accessibility/vision. Store publication and managed deployment are future work. Updates to the app can require reloading the extension. Moving the app requires registering the native host again.

Revoke individual sites in Chrome's extension details → Site access. Turn the app toggle off to stop using the browser backend. Remove the extension to disconnect the native host. To fully uninstall the registration, remove `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.macvoicecontrol.browser.json` in Finder. The private IPC directory is `~/Library/Application Support/MacVoiceControl/BrowserBridge`.

## Why Native Messaging

A normal Chrome profile does not expose CDP by default. Enabling remote debugging on a user's profile broadens access and complicates safe packaging. Native Messaging allows Chrome to launch a code-owned, bundled executable only for the declared extension origin, with user-controlled site permissions and isolated-world scripts. No terminal setup, browser security switch, localhost TCP service, or arbitrary model-generated JavaScript is required.

The host relays bounded messages through a private mailbox, polling every 20ms. This is not the minimum-latency IPC possible; a cancellable Unix-domain socket transport is a reasonable later optimization after Mac measurements. The heartbeat chooses a host connection, and commands remain bound to it for the task. Multi-profile/multi-window behavior needs real-Mac validation; unrelated or inactive tabs are rejected.

## Data and capabilities

Only the foreground active HTTP(S) tab is observed, with at most 60 controls and 6,000 characters of visible evidence. Ordinary field values, password/credential/card inputs, editable drafts and private-marked subtrees are omitted. Link queries/fragments are stripped from public URL context. Only query/fragment-free, non-download links expose verified destination metadata. Page headings, control labels and visible text can still contain personal data and are shared under app screen-context consent.

Actions use observed references in a fixed registry. Targets must remain in the same tab/document and pass identity, semantic state, visibility, enabled, focus and hit-test checks. Text inserts only into a safe focused supported input/textarea, and refuses selected-text replacement. Native selects use a unique observed option label; duplicate labels fail. Frameworks that reject programmatic DOM events require fallback/manual validation.

Canvas, iframes, closed/open shadow trees and complex contenteditable widgets are not traversed. Browser-native dialogs use AX/vision. There are no Gmail/Miro/site-specific scripts. Navigation acknowledgement means dispatch, not task completion. A lost acknowledgement is not automatically replayed.

## Validation boundary

Portable Swift tests and actual Chromium DOM tests run without API keys. The automated browser suite injects Chrome API transport and executes the production content adapter in a real isolated world. It runs the production Swift GoalLoop with mocked Jev choices. It does **not** validate Chrome installation, Native Messaging registration, optional permission prompts, macOS window identity, real speech or live model quality. The native host has a separate real-process framed-stdio test.
