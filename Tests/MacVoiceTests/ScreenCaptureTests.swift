import XCTest
import CoreGraphics
import ImageIO
import VoiceCore
@testable import MacVoice

final class ScreenCaptureTests: XCTestCase {
    func testTinyChangeAtVisualTargetInvalidatesClickEvenOnLargeWindow() throws {
        let geometry = try ImageGeometry.fitted(crop:Rect(-100,200,1280,800))
        func frame(changed: Bool) throws -> CapturedScreen {
            let context = try XCTUnwrap(CGContext(data:nil,width:1280,height:800,bitsPerComponent:8,bytesPerRow:0,
                space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(gray:1,alpha:1)); context.fill(CGRect(x:0,y:0,width:1280,height:800))
            if changed {
                context.setFillColor(CGColor(gray:0,alpha:1)); context.fill(CGRect(x:630,y:390,width:4,height:4))
            }
            return try ScreenCapture.process(XCTUnwrap(context.makeImage()),geometry:geometry,redactions:[])
        }
        let first = try frame(changed:false), changed = try frame(changed:true)
        let point = Point(540,600)
        XCTAssertTrue(try ScreenCapture.targetUnchanged(previous:first.jpeg,current:first.jpeg,geometry:geometry,point:point))
        XCTAssertFalse(try ScreenCapture.targetUnchanged(previous:first.jpeg,current:changed.jpeg,geometry:geometry,point:point))
        XCTAssertThrowsError(try ScreenCapture.targetUnchanged(previous:first.jpeg,current:Data(),geometry:geometry,point:point))
    }
    func testSecureRegionRedactionMatchesTopLeftPixelsAndPreservesOrientation() throws {
        let width = 400, height = 400
        var bytes = [UInt8](repeating:255,count:width*height*4)
        // Distinct top-left and bottom-right markers detect vertical mirroring.
        for y in 20..<80 { for x in 20..<80 {
            let i = (y*width+x)*4; bytes[i] = 255; bytes[i+1] = 0; bytes[i+2] = 0
        } }
        for y in 300..<360 { for x in 300..<360 {
            let i = (y*width+x)*4; bytes[i] = 0; bytes[i+1] = 0; bytes[i+2] = 255
        } }
        let provider = try XCTUnwrap(CGDataProvider(data:Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),
            provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
        let geometry = ImageGeometry(pixelWidth:400,pixelHeight:400,content:Rect(0,0,400,400),desktopCrop:Rect(-100,200,400,400))
        let result = try ScreenCapture.process(image,geometry:geometry,redactions:[Rect(-80,220,60,60)])
        let source = try XCTUnwrap(CGImageSourceCreateWithData(result.jpeg as CFData,nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source,0,nil))
        let pixels = rgba(decoded)
        let redacted = pixel(pixels,x:50,y:50,width:400)
        XCTAssertLessThan(redacted.reduce(0,+),45,"The actual top-left secure field must be black")
        let blue = pixel(pixels,x:330,y:330,width:400)
        XCTAssertGreaterThan(blue[2],200,"Bottom-right marker must retain its orientation")
        XCTAssertLessThan(blue[0],40)
        XCTAssertEqual(result.signature.count,4096)
    }
    func testOutputPaddingAndJpegDimensions() throws {
        let context = try XCTUnwrap(CGContext(data:nil,width:100,height:1000,bitsPerComponent:8,bytesPerRow:0,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray:1,alpha:1)); context.fill(CGRect(x:0,y:0,width:100,height:1000))
        let geometry = try ImageGeometry.fitted(crop:Rect(0,0,100,1000))
        let result = try ScreenCapture.process(XCTUnwrap(context.makeImage()),geometry:geometry,redactions:[])
        let source = try XCTUnwrap(CGImageSourceCreateWithData(result.jpeg as CFData,nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source,0,nil))
        XCTAssertEqual(decoded.width,280); XCTAssertEqual(decoded.height,1000)
        XCTAssertLessThan(pixel(rgba(decoded),x:10,y:500,width:280)[0],50)
        XCTAssertGreaterThan(pixel(rgba(decoded),x:140,y:500,width:280)[0],240)
    }
    private func rgba(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating:0,count:image.width*image.height*4)
        bytes.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data:raw.baseAddress,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,
                space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        }
        return bytes
    }
    private func pixel(_ data:[UInt8],x:Int,y:Int,width:Int) -> [Int] {
        let i = (y*width+x)*4; return data[i..<i+3].map(Int.init)
    }
}
