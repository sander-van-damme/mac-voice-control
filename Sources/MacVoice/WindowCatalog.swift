import CoreGraphics
import Foundation
import VoiceCore

/// Top-to-bottom window-server metadata. No titles, content, or AX values are read.
struct VisibleWindow: Equatable, Sendable {
    let id: CGWindowID, pid: Int32, frame: Rect, layer: Int
}
enum WindowCatalog {
    static func parse(_ entries: [[String:Any]]) -> [VisibleWindow] {
        entries.compactMap { entry in
            guard let id = entry[kCGWindowNumber as String] as? NSNumber,
                  let pid = entry[kCGWindowOwnerPID as String] as? NSNumber,
                  let layer = entry[kCGWindowLayer as String] as? NSNumber,
                  (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue != 0,
                  let bounds = entry[kCGWindowBounds as String] as? [String:Any],
                  let frame = CGRect(dictionaryRepresentation:bounds as CFDictionary) else { return nil }
            let r = Rect(frame.minX,frame.minY,frame.width,frame.height)
            guard r.valid else { return nil }
            return VisibleWindow(id:id.uint32Value,pid:pid.int32Value,frame:r,layer:layer.intValue)
        }
    }
    static func current() -> [VisibleWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] else { return [] }
        return parse(list)
    }
    static func foreground(pid: Int32, windows: [VisibleWindow]) -> VisibleWindow? {
        windows.first { $0.pid == pid && $0.layer == 0 }
    }
    static func unchanged(_ old: VisibleWindow, windows: [VisibleWindow]) -> Bool {
        guard let current = foreground(pid:old.pid,windows:windows) else { return false }
        return current.id == old.id && current.frame.near(old.frame)
    }
    static func exposed(_ window: VisibleWindow, at point: Point, windows: [VisibleWindow]) -> Bool {
        guard window.frame.contains(point), let top = windows.first(where:{$0.frame.contains(point)}) else { return false }
        return top.id == window.id && top.pid == window.pid && top.frame.near(window.frame)
    }
}
