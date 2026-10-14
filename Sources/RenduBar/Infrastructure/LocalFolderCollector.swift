import Foundation
import ImageIO

final class ExportFolderScanner {
    private struct Candidate {
        let url: URL
        let folder: URL
        let size: Int
        let modified: Date
        let ext: String
    }

    private struct Stamp {
        let size: Int64
        let modified: Date
        let seenAt: Date
    }

    private(set) var health = SourceHealth()
    private(set) var supportedFileCount = 0
    private(set) var listingTruncated = false
    private var stamps: [String: Stamp] = [:]
    private var validatedImages = Set<String>()
    private let allowed = Set(["png", "jpg", "jpeg", "tif", "tiff", "exr", "mov", "mp4", "m4v", "avi",
                               "wav", "aif", "aiff", "flac", "mp3", "m4a", "aac", "ogg",
                               "pdf", "glb", "gltf", "usdz"])
    private let decodableImages = Set(["png", "jpg", "jpeg", "tif", "tiff"])

    func scan(paths: [String], now: Date = Date(), limit: Int = 80, validateImages: Bool = true) -> [RenderEntry] {
        var candidates: [Candidate] = []
        var result: [RenderEntry] = []
        var liveIDs = Set<String>()
        var candidatePaths = Set<String>()
        var missing = 0
        for raw in paths {
            if Task.isCancelled { break }
            let folder = URL(fileURLWithPath: raw, isDirectory: true).resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  let children = try? FileManager.default.contentsOfDirectory(
                    at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles]) else { missing += 1; continue }
            candidates += children.compactMap { file -> Candidate? in
                let ext = file.pathExtension.lowercased()
                guard allowed.contains(ext),
                      !file.lastPathComponent.lowercased().contains("screenshot"),
                      !file.lastPathComponent.lowercased().contains("capture d’écran"),
                      let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]),
                      values.isRegularFile == true, values.isSymbolicLink != true,
                      let size = values.fileSize, size > 0,
                      let modified = values.contentModificationDate else { return nil }
                guard candidatePaths.insert(file.standardizedFileURL.path).inserted else { return nil }
                return Candidate(url: file, folder: folder, size: size, modified: modified, ext: ext)
            }
        }
        supportedFileCount = candidates.count
        listingTruncated = candidates.count > limit
        health.online = !paths.isEmpty && missing < paths.count
        health.partial = missing > 0 && health.online
        health.isStale = !health.online
        health.checkedAt = now
        if health.online { health.lastGoodAt = now; health.observedAt = now }
        health.message = paths.isEmpty ? "Aucun dossier Mac ajouté" : "\(candidates.count) fichiers pris en charge · \(missing) dossier(s) indisponible(s)" + (listingTruncated ? " · \(limit) plus récents affichés" : "")
        var remainingValidations = validateImages ? 6 : 0
        for candidate in candidates.sorted(by: { $0.modified > $1.modified }).prefix(max(0, limit)) {
            if Task.isCancelled { break }
            let file = candidate.url
            let size = candidate.size
            let modified = candidate.modified
            let ext = candidate.ext
            let id = "mac-folder:" + file.standardizedFileURL.path + ":\(size):\(modified.timeIntervalSince1970)"
            liveIDs.insert(id)
            let previous = stamps[id]
            if previous == nil { validatedImages.remove(id) }
            let unchanged = previous?.size == Int64(size) && previous?.modified == modified
            let seenAt = unchanged ? (previous?.seenAt ?? now) : now
            stamps[id] = Stamp(size: Int64(size), modified: modified, seenAt: seenAt)
            let dwell = RenderKind.classify(file.lastPathComponent) == .image ? 5.0 : 20.0
            let stable = unchanged && now.timeIntervalSince(seenAt) >= dwell
                && now.timeIntervalSince(modified) >= dwell
            var state: RenderState = stable ? .stable : .pending
            if stable && decodableImages.contains(ext) {
                if validatedImages.contains(id) {
                    state = .complete
                } else if remainingValidations > 0 {
                    remainingValidations -= 1
                    if Self.canDecode(file, expectedSize: size, expectedModified: modified) {
                        validatedImages.insert(id)
                        state = .complete
                    }
                }
            }
            result.append(RenderEntry(id: id, source: .macFolder,
                                      job: candidate.folder.lastPathComponent,
                                      filename: file.lastPathComponent, modified: modified,
                                      state: state, path: file.path, previewURL: nil))
        }
        stamps = stamps.filter { liveIDs.contains($0.key) }
        validatedImages.formIntersection(liveIDs)
        return result
    }

    private static func canDecode(_ url: URL, expectedSize: Int, expectedModified: Date) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { return false }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 64]
        guard CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) != nil,
              let after = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return false }
        return after.fileSize == expectedSize && after.contentModificationDate == expectedModified
    }
}


struct FolderCollectionResult {
    let entries: [RenderEntry]
    let health: SourceHealth
}

actor FolderCollectionWorker {
    private let scanner = ExportFolderScanner()
    private let historyScanner = ExportFolderScanner()
    func scan(_ paths: [String]) -> FolderCollectionResult {
        let entries = scanner.scan(paths: paths)
        return FolderCollectionResult(entries: entries, health: scanner.health)
    }
    func history(_ paths: [String]) -> FolderCollectionResult {
        let entries = historyScanner.scan(paths: paths, limit: Int.max, validateImages: false)
        return FolderCollectionResult(entries: entries, health: historyScanner.health)
    }
}

