import AppKit
import Foundation

@main
enum ExportIcon {
    static func main() throws {
        guard CommandLine.arguments.count == 2,
              let tiff = RenduLogo.app.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "RenduBar.Icon", code: 1)
        }
        try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
    }
}
