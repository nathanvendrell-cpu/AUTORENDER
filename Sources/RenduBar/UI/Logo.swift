import AppKit

enum RenduLogo {
    static let menu: NSImage = draw(size: 19, monochrome: true)
    static let app: NSImage = draw(size: 1024, monochrome: false)

    private static func draw(size: CGFloat, monochrome: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let unit = size / 100
            let ink = monochrome ? NSColor.black : NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.16, alpha: 1)
            let accent = monochrome ? NSColor.black : NSColor(calibratedRed: 0.23, green: 0.40, blue: 0.86, alpha: 1)
            let warm = monochrome ? NSColor.black : NSColor(calibratedRed: 0.82, green: 0.49, blue: 0.17, alpha: 1)
            if !monochrome {
                NSColor(calibratedRed: 0.97, green: 0.96, blue: 0.94, alpha: 1).setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 2 * unit, dy: 2 * unit), xRadius: 24 * unit, yRadius: 24 * unit).fill()
            }
            func frame(_ x: CGFloat, _ y: CGFloat, _ color: NSColor) {
                let shape = NSBezierPath(roundedRect: NSRect(x: x * unit, y: y * unit, width: 58 * unit, height: 48 * unit),
                                         xRadius: 9 * unit, yRadius: 9 * unit)
                shape.lineWidth = max(1.6, 5.5 * unit)
                color.setStroke()
                shape.stroke()
            }
            frame(14, 18, warm)
            frame(26, 29, accent)
            frame(38, 40, ink)
            ink.setFill()
            NSBezierPath(ovalIn: NSRect(x: 73 * unit, y: 64 * unit,
                                        width: 11 * unit, height: 11 * unit)).fill()
            return true
        }
        image.isTemplate = monochrome
        return image
    }
}
