import Foundation

@main
enum FormatScannerSmoke {
    static func main() throws {
        let directory = CommandLine.arguments[1]
        let scanner = ExportFolderScanner()
        let now = Date()
        let first = scanner.scan(paths: [directory], now: now)
        let second = scanner.scan(paths: [directory], now: now.addingTimeInterval(21))
        let expected = Set(["png", "jpg", "jpeg", "tif", "tiff", "exr", "mp4", "mov", "m4v", "avi", "wav", "aif", "aiff", "flac", "mp3", "m4a", "aac", "ogg", "pdf", "glb", "gltf", "usdz"])
        guard Set(first.map { ($0.filename as NSString).pathExtension }) == expected,
              first.allSatisfy({ $0.state == .pending }), second.count == expected.count + 2 else {
            throw NSError(domain: "FormatCoverage", code: 1)
        }
        for entry in second {
            let ext = (entry.filename as NSString).pathExtension
            let decoded = ["png", "jpg", "jpeg"].contains(ext) || entry.filename.hasPrefix("rgb-")
            guard entry.state == (decoded ? .complete : .stable) else {
                throw NSError(domain: "FormatState-" + ext, code: 2)
            }
            print("\(ext): \(entry.kind.rawValue), \(entry.state.rawValue)")
        }
        let audio = second.first { $0.filename == "sound.wav" }!
        let still = second.first { $0.filename == "image.png" }!
        guard RenderOrganization.workType(for: audio, jobs: [], knownFolders: [:], configured: [directory: .audio]) == .audio,
              RenderOrganization.workType(for: still, jobs: [], knownFolders: [:], configured: [directory: .image]) == .image else {
            throw NSError(domain: "DeclaredWorkType", code: 3)
        }
        let sequenceFolder = CommandLine.arguments[2]
        let frames = ExportFolderScanner().scan(paths: [sequenceFolder])
        let job = MacJob(id: "fixture-sequence", titre: "Demo sequence — frames", sous: nil, total: 3, faites: 3,
                         en_cours: [], latest: frames.map(\.filename), times: [], proc: nil, workType: .video)
        let known = [job.id: sequenceFolder]
        guard frames.count == 3, frames.allSatisfy({ $0.fileMediaType == .image && RenderOrganization.workType(for: $0,
              jobs: [job], knownFolders: known, configured: [:]) == .video }),
              Set(frames.map { RenderOrganization.projectID(for: $0, jobs: [job], knownFolders: known, labels: [:]) }).count == 1 else {
            throw NSError(domain: "VideoSequenceGrouping", code: 4)
        }
        print("Real PNG video sequence: 3 frames, one stable job identity, declared Video; WAV Audio and PNG Image user choices preserved")
        print("FormatScannerSmoke: \(expected.count) formats listed; 5 ImageIO decoded; 2 YUV TIFF unsupported by ImageIO; other media stay Stable")
    }
}
