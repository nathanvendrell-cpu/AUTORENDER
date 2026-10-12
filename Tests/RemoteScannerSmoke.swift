import AppKit
import Darwin
import Foundation
import ImageIO

@main
enum RemoteScannerSmoke {
    @MainActor static func main() async throws {
        let roots = (RenduStorage.load("config.json", as: AppConfig.self) ?? AppConfig.bootstrap()).shadowFolders
        guard !roots.isEmpty else {
            print("RemoteScannerSmoke: SKIP — aucun dossier Shadow configuré localement")
            return
        }
        let scanner = ShadowFolderScanner()
        defer { scanner.cancel() }
        let first = await scanner.scan(roots)
        print("Premier scan : online=\(scanner.health.online), message=\(scanner.health.message), fichiers=\(first.count)")
        if let sample = first.first { print("Premier horodatage : \(sample.modified)") }
        fflush(stdout)
        guard scanner.health.online, !first.isEmpty,
              first.allSatisfy({ $0.modified < Date() }) else {
            throw NSError(domain: "RenduBar.RemoteScanner", code: 1)
        }
        try await Task.sleep(for: .seconds(9))
        let second = await scanner.scan(roots)
        guard scanner.health.online,
              second.contains(where: { $0.state == .stable }) else {
            throw NSError(domain: "RenduBar.RemoteScanner", code: 2)
        }
        guard let candidate = second.first(where: {
            $0.state == .stable && ["png", "jpg", "jpeg"].contains(($0.filename as NSString).pathExtension.lowercased())
        }), let path = candidate.path,
              let preview = await scanner.preview(path, roots: roots, id: candidate.id),
              let source = CGImageSourceCreateWithData(preview as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw NSError(domain: "RenduBar.RemoteScanner", code: 3)
        }
        print("Shadow direct : \(roots.count) dossiers, \(second.count) fichiers, horodatage UTC et stabilité vérifiés ; aperçu \(preview.count) octets")
    }
}
