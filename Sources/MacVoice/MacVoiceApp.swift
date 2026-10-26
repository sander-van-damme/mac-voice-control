import SwiftUI
import VoiceCore

@main @MainActor struct MacVoiceApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup("Mac Voice Control",id:"main") {
            MainView(model:model).onReceive(NotificationCenter.default.publisher(for:NSApplication.willTerminateNotification)) { _ in model.stop() }
        }
        .defaultSize(width:520,height:600)
        .windowResizability(.contentSize)
        MenuBarExtra("Mac Voice Control",systemImage:model.listening ? "waveform.circle.fill" : "mic.circle") {
            Text(model.phase.rawValue)
            Text(model.message).font(.caption)
            Divider()
            Button(model.listening ? "Stop" : "Start") { model.listening ? model.stop() : model.start() }
            if model.pending != nil {
                Button("Confirm action") { model.confirm(true) }
                Button("Cancel action") { model.confirm(false) }
            }
            OpenWindowButton()
            Button("Quit") { model.stop(); NSApp.terminate(nil) }
        }
        Settings { SetupView(model:model).padding(24).frame(width:520).onAppear { model.stop() } }
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool { false }
}
private struct OpenWindowButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View { Button("Show controls") { openWindow(id:"main"); NSApp.activate(ignoringOtherApps:true) } }
}
struct MainView: View {
    @ObservedObject var model: AppModel
    @State private var typed = ""
    @State private var diagnostics = false
    var body: some View {
        VStack(alignment:.leading,spacing:20) {
            HStack {
                Image(systemName:"waveform.circle.fill").font(.system(size:40)).foregroundStyle(.teal)
                VStack(alignment:.leading) {
                    Text("Mac Voice Control").font(.title2.bold())
                    Text("Your voice. Your Mac.").foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.stop(); model.setupVisible.toggle() } label: { Image(systemName:"gearshape") }.help("Setup and settings")
            }
            HStack {
                Circle().fill(model.listening ? Color.teal : Color.secondary).frame(width:9,height:9)
                Text(model.phase.rawValue).font(.headline)
                Spacer()
                Text("EXPERIMENTAL").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
            Text(model.message).font(.body).frame(maxWidth:.infinity,alignment:.leading).fixedSize(horizontal:false,vertical:true)
            Button { model.listening ? model.stop() : model.start() } label: {
                Label(model.listening ? "Stop" : "Start listening",systemImage:model.listening ? "stop.fill" : "mic.fill")
                    .font(.title3.weight(.semibold)).frame(maxWidth:.infinity).padding(.vertical,12)
            }.buttonStyle(.borderedProminent).tint(model.listening ? .red : .teal).keyboardShortcut(.escape,modifiers:[])
            if let pending = model.pending {
                VStack(alignment:.leading,spacing:10) {
                    Label("Your confirmation is needed",systemImage:"hand.raised.fill").font(.headline)
                    Text(pending)
                    if let data = model.pendingImage, let image = NSImage(data:data), let marker = model.pendingMarker {
                        VisualPreview(image:image,marker:marker)
                    }
                    Text("Say “confirm / bevestig” or “cancel / annuleer”. Expires after 25 seconds.").font(.caption).foregroundStyle(.secondary)
                    HStack { Button("Confirm") { model.confirm(true) }; Button("Cancel",role:.cancel) { model.confirm(false) } }
                }.padding().background(.orange.opacity(0.1),in:RoundedRectangle(cornerRadius:12))
            }
            if !model.transcript.isEmpty { Text(model.transcript).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            if model.setupVisible || !model.ready {
                SetupView(model:model)
            } else {
                VStack(alignment:.leading,spacing:8) {
                    Text("Try saying").font(.headline)
                    Text("“Hey Jev, open Chrome.”\n“Hey Jev, open een nieuw tabblad.”\n“Hey Jev, type ‘Hello, hoe gaat het?’”").foregroundStyle(.secondary)
                    Text("Start hides this window so you can work. Controls stay in the menu bar. Audio is processed locally; screen context goes to TypeSafe.").font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup("Type a command",isExpanded:$diagnostics) {
                    HStack { TextField("Open Chrome",text:$typed); Button("Run") { model.submitTyped(typed); typed = "" }.disabled(!model.listening || typed.isEmpty) }
                    Text("For troubleshooting. Voice commands use the same decision loop.").font(.caption)
                    if !model.timings.isEmpty {
                        Text(model.timings.sorted(by:{$0.key < $1.key}).map { "\($0.key): \(Int($0.value)) ms" }.joined(separator:" · ")).font(.caption2).textSelection(.enabled)
                        Text("\(model.tokens) input tokens · estimated $\(model.estimatedCost,specifier:"%.6f")").font(.caption2)
                    }
                }
            }
        }.padding(26).frame(width:520).onReceive(NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification)) { _ in model.refreshPermissions() }
    }
}
private struct VisualPreview: View {
    let image: NSImage
    let marker: Point
    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width/image.size.width,proxy.size.height/image.size.height)
            let width = image.size.width*scale, height = image.size.height*scale
            Image(nsImage:image).resizable().frame(width:width,height:height)
                .overlay(alignment:.topLeading) {
                    Image(systemName:"scope").font(.title).foregroundStyle(.red)
                        .position(x:width*marker.x,y:height*marker.y)
                }.frame(width:proxy.size.width,height:proxy.size.height)
        }.frame(height:200).accessibilityLabel("Screenshot of the proposed visual click, with a red target marker")
    }
}
struct SetupView: View {
    @ObservedObject var model: AppModel
    @State private var apiKey = ""
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            Text("Setup").font(.headline)
            HStack {
                SecureField(model.keySaved ? "Replace TypeSafe API key" : "TypeSafe API key",text:$apiKey)
                Button("Save") { model.saveKey(apiKey); apiKey = "" }.disabled(apiKey.trimmingCharacters(in:.whitespaces).isEmpty)
                if model.keySaved { Image(systemName:"checkmark.circle.fill").foregroundStyle(.green) }
            }
            HStack {
                Link("Get a TypeSafe key",destination:URL(string:"https://console.typesafe.ai/")!)
                Spacer()
                if model.keySaved { Button("Remove key",role:.destructive) { model.forgetKey() }.font(.caption) }
            }.font(.caption)
            Toggle("Allow screen context to be sent to TypeSafe",isOn:$model.consent)
            Text("Only while executing your commands. Visible documents may contain private information. Known password fields are masked; other sensitive content may still appear. No screenshots or audio are saved.").font(.caption).foregroundStyle(.secondary)
            HStack {
                permission("Microphone",granted:model.microphone,action:model.requestMicrophone)
                permission("Accessibility",granted:model.accessibility,action:model.requestAccessibility)
                permission("Screen Recording",granted:model.screenRecording,action:model.requestScreen)
            }
            HStack {
                Button("Refresh permissions") { model.refreshPermissions() }
                Button(model.quickStop ? "Fast spoken stop enabled" : "Enable faster spoken stop") { model.requestQuickStop() }.disabled(model.quickStop)
            }.font(.caption)
            Text("After granting Screen Recording, quit and reopen the app. Faster stop uses Apple’s on-device English recognizer when available; Dutch and English cancellation also run through the main local model.").font(.caption2).foregroundStyle(.secondary)
            Divider()
            Text(model.downloadMessage).font(.callout)
            if model.downloading {
                ProgressView(value:model.modelProgress)
                Button("Cancel download") { model.cancelDownload() }
            } else {
                Button(model.modelReady ? "Speech model ready" : "Download / load local speech model") { model.downloadModel() }.disabled(model.modelReady)
                Text("Apple Silicon required. Allow roughly 1 GB of free space; downloads from Hugging Face, then works offline. Model loading is required after relaunch; cached files are reused.").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(16).background(.quaternary.opacity(0.5),in:RoundedRectangle(cornerRadius:12))
    }
    private func permission(_ name:String,granted:Bool,action:@escaping ()->Void) -> some View {
        Button(action:action) { Label(name,systemImage:granted ? "checkmark.circle.fill" : "circle").font(.caption) }
            .tint(granted ? .green : .accentColor)
    }
}
