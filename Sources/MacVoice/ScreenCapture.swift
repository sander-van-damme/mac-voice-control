import AppKit
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers
import VoiceCore

struct CapturedScreen {
    let jpeg: Data, signature: [UInt8], geometry: ImageGeometry
    var timings: [String:Double] = [:]
}
enum ScreenCapture {
    /// A global thumbnail can hide a changed icon. Compare actual color pixels around a visual click too.
    static func targetUnchanged(previous: Data, current: Data, geometry: ImageGeometry, point: Point) throws -> Bool {
        let center = try geometry.imagePoint(for:point)
        let region = CGRect(x:max(0,Int(center.x)-32),y:max(0,Int(center.y)-32),width:64,height:64)
            .intersection(CGRect(x:0,y:0,width:geometry.pixelWidth,height:geometry.pixelHeight)).integral
        func pixels(_ data: Data) throws -> [UInt8] {
            guard let source = CGImageSourceCreateWithData(data as CFData,nil),
                  let image = CGImageSourceCreateImageAtIndex(source,0,nil),
                  image.width == geometry.pixelWidth, image.height == geometry.pixelHeight,
                  let patch = image.cropping(to:region) else { throw VoiceError("Could not verify the visual target.") }
            var result = [UInt8](repeating:0,count:patch.width*patch.height*4)
            let created = result.withUnsafeMutableBytes { raw -> Bool in
                guard let context = CGContext(data:raw.baseAddress,width:patch.width,height:patch.height,
                    bitsPerComponent:8,bytesPerRow:patch.width*4,space:CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.draw(patch,in:CGRect(x:0,y:0,width:patch.width,height:patch.height)); return true
            }
            guard created else { throw VoiceError("Could not verify visual pixels.") }; return result
        }
        let before = try pixels(previous), after = try pixels(current)
        return zip(before,after).allSatisfy { abs(Int($0)-Int($1)) <= 24 }
    }
    static func capture(window: Rect, redactions: [Rect]) async throws -> CapturedScreen {
        let captureStart = MonotonicTime.now
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
        let captureMilliseconds = (MonotonicTime.now-captureStart)*1000
        var result = try process(image,geometry:g,redactions:redactions)
        result.timings["screenshot_capture_ms"] = captureMilliseconds
        return result
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
        let encodingStart = MonotonicTime.now
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data,UTType.jpeg.identifier as CFString,1,nil) else { throw VoiceError("Could not encode the screenshot.") }
        CGImageDestinationAddImage(dest,output,[kCGImageDestinationLossyCompressionQuality:0.78] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw VoiceError("Screenshot encoding failed.") }
        let encodingMilliseconds = (MonotonicTime.now-encodingStart)*1000
        var signature = [UInt8](repeating:0,count:64*64)
        signature.withUnsafeMutableBytes { raw in
            if let tiny = CGContext(data:raw.baseAddress,width:64,height:64,bitsPerComponent:8,bytesPerRow:64,
                space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGImageAlphaInfo.none.rawValue) {
                tiny.interpolationQuality = .low; tiny.draw(output,in:CGRect(x:0,y:0,width:64,height:64))
            }
        }
        return CapturedScreen(jpeg:data as Data,signature:signature,geometry:g,timings:["screenshot_encoding_ms":encodingMilliseconds])
    }
}
private extension CGRect { var area: CGFloat { isNull ? 0 : width*height } }
