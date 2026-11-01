import AppKit
import VoiceCore

@MainActor enum BrowserSetup {
    static func install() throws {
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/MacVoiceBrowserHost")
        let extensionDirectory = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/BrowserExtension")
        guard FileManager.default.isExecutableFile(atPath:executable.path),
              FileManager.default.fileExists(atPath:extensionDirectory.appendingPathComponent("manifest.json").path) else {
            throw VoiceError("Install a packaged application first. The development executable does not contain the browser extension and host.")
        }
        let directory = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("Google/Chrome/NativeMessagingHosts",isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let manifest: [String:Any] = ["name":"com.macvoicecontrol.browser","description":"Mac Voice Control browser bridge",
            "path":executable.path,"type":"stdio","allowed_origins":["chrome-extension://jmfolbhhccnileefopndlkjokamifggp/"]]
        try JSONSerialization.data(withJSONObject:manifest,options:[.sortedKeys,.prettyPrinted])
            .write(to:directory.appendingPathComponent("com.macvoicecontrol.browser.json"),options:.atomic)
        NSWorkspace.shared.open(extensionDirectory)
        if let url = URL(string:"chrome://extensions"), let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.google.Chrome") {
            NSWorkspace.shared.open([url],withApplicationAt:chrome,configuration:NSWorkspace.OpenConfiguration(),completionHandler: { _,_ in })
        }
    }
}
