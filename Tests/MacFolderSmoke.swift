import AppKit
import Foundation

@main
enum MacFolderSmoke {
    static func main() throws {
        let folders = AppConfig.bootstrap().macFolders
        guard !folders.isEmpty else { throw NSError(domain: "RenduBar.MacFolder", code: 1) }
        let scanner = ExportFolderScanner()
        let now = Date()
        let first = scanner.scan(paths: folders, now: now)
        let second = scanner.scan(paths: folders, now: now.addingTimeInterval(6))
        guard !first.isEmpty, second.contains(where: { $0.state == .complete }) else {
            throw NSError(domain: "RenduBar.MacFolder", code: 2)
        }
        print("Mac direct : \(folders.count) dossiers, \(second.count) exports récents, "
              + "\(second.filter { $0.state == .complete }.count) images décodables et stables")
    }
}
