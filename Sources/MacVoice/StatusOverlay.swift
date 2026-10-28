import SwiftUI
import AppKit
import VoiceCore

private final class StatusPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor final class StatusOverlay {
    private let panel: NSPanel
    private weak var model: AppModel?
    private var anchor: NSPoint?
    private var placing = false
    private var moveObserver: NSObjectProtocol?
    init(model: AppModel) {
        self.model = model
        panel = StatusPanel(contentRect:NSRect(x:0,y:0,width:380,height:230),
            styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.level = .floating; panel.isFloatingPanel = true; panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false; panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.ignoresCycle,.stationary]
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = true
        // ScreenCapture already excludes this application's windows.
        let hosting = NSHostingView(rootView:StatusOverlayView(model:model))
        hosting.sizingOptions = []
        panel.contentView = hosting
        moveObserver = NotificationCenter.default.addObserver(forName:NSWindow.didMoveNotification,object:panel,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.placing else { return }
                self.anchor = self.panel.frame.origin
            }
        }
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x:f.maxX-400,y:f.minY+24))
        }
    }
    func show() {
        let height: CGFloat = model?.pending == nil ? 190 : model?.pendingImage == nil ? 260 : 390
        placing = true
        defer { placing = false }
        let origin = anchor ?? panel.frame.origin
        if anchor == nil { anchor = origin }
        panel.setContentSize(NSSize(width:380,height:height))
        let bounds = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        let y = bounds.map { min(max(origin.y,$0.minY+16),$0.maxY-height-16) } ?? origin.y
        let x = bounds.map { min(max(origin.x,$0.minX+16),$0.maxX-396) } ?? origin.x
        panel.setFrameOrigin(NSPoint(x:x,y:y))
        DebugLog.shared.event("overlay.layout",["x":String(x),"y":String(y),"height":String(height),"anchor_y":String(origin.y)])
        panel.orderFrontRegardless()
    }
    var frame: NSRect { panel.frame }
    func hide() { panel.orderOut(nil) }
    deinit { if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) } }
}

struct StatusOverlayView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            HStack {
                Image(systemName:"waveform").foregroundStyle(.teal)
                Text(model.phase.rawValue).font(.headline)
                Spacer()
                Button("Stop",role:.destructive) { model.stop() }.buttonStyle(.borderedProminent).tint(.red)
            }
            if !model.transcript.isEmpty { Text(model.transcript).font(.callout).lineLimit(3) }
            Text(model.message).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            if let pending = model.pending {
                Text(pending).font(.caption).lineLimit(2)
                if let image = model.pendingImage.flatMap(NSImage.init(data:)), let marker = model.pendingMarker {
                    VisualPreview(image:image,marker:marker,height:120)
                }
                HStack {
                    Button("Confirm") { model.confirm(true) }
                    Button("Cancel") { model.confirm(false) }
                    Text("Expires after 25 seconds").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }.padding(16).frame(width:380,alignment:.leading)
            .background(.regularMaterial,in:RoundedRectangle(cornerRadius:16))
            .overlay(RoundedRectangle(cornerRadius:16).stroke(.secondary.opacity(0.2)))
    }
}

struct ChatGPTSetupView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var account: ChatGPTAccount
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            Text("Language assistance").font(.headline)
            Text("Local speech and TypeSafe Jev stay in use. ChatGPT helps interpret difficult requests and prepare text. All computer actions run through this app.").font(.caption).foregroundStyle(.secondary)
            Text(account.status).font(.caption)
            HStack {
                Button(account.connected ? "Reconnect ChatGPT" : "Continue with ChatGPT") { model.stop(); account.signIn() }.disabled(account.busy)
                if account.busy { Button("Cancel sign-in") { account.cancelSignIn() } }
                if account.connected {
                    Button("Disconnect") { model.stop(); model.languageEnabled = false; account.disconnect() }.disabled(account.busy)
                }
            }
            if account.connected {
                Button("Use another ChatGPT account") { model.stop(); account.signIn(newAccount:true) }.font(.caption).disabled(account.busy)
                Toggle("Use ChatGPT for language assistance",isOn:$model.languageEnabled)
                if account.models.isEmpty {
                    TextField("Model ID",text:$account.model)
                } else {
                    Picker("Model",selection:$account.model) { ForEach(account.models) { Text($0.name).tag($0.id) } }
                }
                Button("Refresh available models") { account.refreshModels() }.font(.caption).disabled(account.busy)
                Toggle("Share screen context with ChatGPT",isOn:$model.languageScreenContext)
                Text("Language assistance sends your command and recent action outcomes to OpenAI. Screen context additionally includes the screenshot and relevant Accessibility controls; use it for requests about what is on screen. Audio stays local. Usage counts toward your ChatGPT plan.").font(.caption2).foregroundStyle(.secondary)
                Link("Manage ChatGPT plan usage",destination:URL(string:"https://chatgpt.com/#settings/Usage")!).font(.caption)
            }
        }.onChange(of:account.model) { _,_ in model.stop() }
    }
}
