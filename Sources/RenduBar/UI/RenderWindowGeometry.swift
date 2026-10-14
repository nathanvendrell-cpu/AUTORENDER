import Foundation
import CoreGraphics

/// Pure frame policy in screen points. No preferences, windows or screen APIs.
enum RenderWindowGeometry {
    struct Placement {
        let frame: NSRect
        let minimum: NSSize
    }

    static func isValid(_ rect: NSRect) -> Bool {
        [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height,
         rect.maxX, rect.maxY].allSatisfy { $0.isFinite }
            && rect.size.width > 0 && rect.size.height > 0
    }

    static func resolve(saved: NSRect?, screens: [NSRect], fallbackScreen: NSRect?,
                        initial: NSSize, minimum: NSSize) -> Placement? {
        let available = screens.filter(isValid)
        guard !available.isEmpty else { return nil }
        let saved = saved.flatMap { isValid($0) ? $0 : nil }
        let fallback = fallbackScreen.flatMap { candidate in available.first { $0 == candidate } } ?? available[0]
        let screen: NSRect
        if let saved {
            // Prefer the screen carrying most of the window, not any tiny intersection.
            let areas = available.map { overlapArea(saved, $0) }
            if let best = areas.max(), best > 0, let index = areas.firstIndex(of: best) {
                screen = available[index]
            } else {
                // Removed displays: recover to the nearest remaining screen.
                screen = available.min { distance(saved, $0) < distance(saved, $1) } ?? fallback
            }
        } else {
            screen = fallback
        }
        let effectiveMinimum = NSSize(width: min(minimum.width, screen.width),
                                      height: min(minimum.height, screen.height))
        let proposed = saved?.size ?? initial
        let size = NSSize(width: min(max(proposed.width, effectiveMinimum.width), screen.width),
                          height: min(max(proposed.height, effectiveMinimum.height), screen.height))
        // Preserve the top edge when repairing a tiny frame; keep valid user frames exact.
        let origin = saved.map { NSPoint(x: $0.minX, y: $0.maxY - size.height) }
            ?? NSPoint(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2)
        let frame = NSRect(x: min(max(origin.x, screen.minX), screen.maxX - size.width),
                           y: min(max(origin.y, screen.minY), screen.maxY - size.height),
                           width: size.width, height: size.height)
        return Placement(frame: frame, minimum: effectiveMinimum)
    }

    private static func overlapArea(_ a: NSRect, _ b: NSRect) -> CGFloat {
        max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX))
            * max(0, min(a.maxY, b.maxY) - max(a.minY, b.minY))
    }

    private static func distance(_ a: NSRect, _ b: NSRect) -> CGFloat {
        // hypot avoids overflow when a corrupted finite coordinate is very large.
        hypot(a.midX - b.midX, a.midY - b.midY)
    }
}
