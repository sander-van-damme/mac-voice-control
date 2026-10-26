import AppKit
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers
import VoiceCore

struct CapturedScreen {
    let jpeg: Data, signature: [UInt8], geometry: ImageGeometry
}
enum ScreenCapture {
    static func capture(window: Rect, redactions: [Rect]) async throws -> CapturedScreen {
        guard CGPreflightScreenCaptureAccess() else { throw VoiceError("Enable Screen Recording in System Settings, then quit and reopen Mac Voice Control.") }
        let shareable = try await SCShareableContent.excludingDesktopWindows(true,onScreenWindowsOnly:true)
        try Task.checkCancellation()
        let windowRect = CGRect(x:window.x,y:window.y,width:window.width,height:window.height)
        guard let display = shareable.displays.max(by: {
            $0.frame.intersection(windowRect).area < $1.frame.intersection(windowRect).area
        }) else { throw VoiceError("No display is available.") }
        let crop = display.frame.intersection(windowRect)
        guard !crop.isNull, crop.width > 1, crop.height > 1 else { throw VoiceError("The window is not visible on a display.") }
        let own = shareable.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display:display,excludingApplications:own,exceptingWindows:[])
        let config = SCStreamConfiguration()
        // sourceRect is in display-local points; output dimensions are pixels.
        config.sourceRect = CGRect(x:crop.minX-display.frame.minX,y:crop.minY-display.frame.minY,width:crop.width,height:crop.height)
        let g = try ImageGeometry.fitted(crop:Rect(crop.minX,crop.minY,crop.width,crop.height))
        config.width = Int(g.content.width); config.height = Int(g.content.height)
        config.showsCursor = false; config.capturesAudio = false
        let image = try await SCScreenshotManager.captureImage(contentFilter:filter,configuration:config)
        try Task.checkCancellation()
        return try process(image,geometry:g,redactions:redactions)
    }
    static func process(_ image: CGImage, geometry g: ImageGeometry, redactions: [Rect]) throws -> CapturedScreen {
        guard let ctx = CGContext(data:nil,width:g.pixelWidth,height:g.pixelHeight,bitsPerComponent:8,bytesPerRow:0,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw VoiceError("Could not prepare the screenshot.") }
        ctx.setFillColor(CGColor(gray:0.12,alpha:1)); ctx.fill(CGRect(x:0,y:0,width:g.pixelWidth,height:g.pixelHeight))
        // Quartz bitmap drawing uses bottom-left coordinates; the exported image uses top-left.
        let contentRect = CGRect(x:g.content.x,y:Double(g.pixelHeight)-g.content.y-g.content.height,width:g.content.width,height:g.content.height)
        ctx.draw(image,in:contentRect)
        ctx.setFillColor(CGColor(gray:0,alpha:1))
        for r in redactions {
            let x = g.content.x + (r.x-g.desktopCrop.x)/g.desktopCrop.width*g.content.width
            let top = g.content.y + (r.y-g.desktopCrop.y)/g.desktopCrop.height*g.content.height
            let w = r.width/g.desktopCrop.width*g.content.width, h = r.height/g.desktopCrop.height*g.content.height
            ctx.fill(CGRect(x:x-4,y:Double(g.pixelHeight)-top-h-4,width:w+8,height:h+8))
        }
        guard let output = ctx.makeImage() else { throw VoiceError("Could not redact the screenshot.") }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data,UTType.jpeg.identifier as CFString,1,nil) else { throw VoiceError("Could not encode the screenshot.") }
        CGImageDestinationAddImage(dest,output,[kCGImageDestinationLossyCompressionQuality:0.78] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw VoiceError("Screenshot encoding failed.") }
        var signature = [UInt8](repeating:0,count:64*64)
        signature.withUnsafeMutableBytes { raw in
            if let tiny = CGContext(data:raw.baseAddress,width:64,height:64,bitsPerComponent:8,bytesPerRow:64,
                space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGImageAlphaInfo.none.rawValue) {
                tiny.interpolationQuality = .low; tiny.draw(output,in:CGRect(x:0,y:0,width:64,height:64))
            }
        }
        return CapturedScreen(jpeg:data as Data,signature:signature,geometry:g)
    }
}
private extension CGRect { var area: CGFloat { isNull ? 0 : width*height } }
