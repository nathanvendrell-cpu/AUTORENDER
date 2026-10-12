import AppKit
import Foundation

@main
struct ScannerTests {
    static var assertions = 0

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !condition() { fatalError(message) }
    }

    @MainActor static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .calibratedRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.setColor(.white, atX: 0, y: 0)
        let png = bitmap.representation(using: .png, properties: [:])!
        let image = directory.appendingPathComponent("frame_0001.png")
        try png.write(to: image)
        try Data("not a render".utf8).write(to: directory.appendingPathComponent("scene.blend"))
        try png.write(to: directory.appendingPathComponent("Screenshot_2026.png"))
        let now = Date()
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-30)], ofItemAtPath: image.path)
        let scanner = ExportFolderScanner()
        let first = scanner.scan(paths: [directory.path], now: now)
        require(first.count == 1, "non-render files must be excluded")
        require(first[0].state == .pending, "first observation must not claim completion")
        let second = scanner.scan(paths: [directory.path], now: now.addingTimeInterval(6))
        require(second.count == 1 && second[0].state == .complete, "stable decodable PNG must complete")
        require(scanner.scan(paths: [directory.path, directory.path], now: now.addingTimeInterval(6)).count == 1,
                "same configured folder must not duplicate a render")
        require(first[0].id == second[0].id, "identity must be stable across unchanged scans")
        let typed = directory.appendingPathComponent("typed", isDirectory: true)
        try FileManager.default.createDirectory(at: typed, withIntermediateDirectories: true)
        for name in ["clip.mp4", "mix.wav", "scene.glb", "source.blend"] {
            let file = typed.appendingPathComponent(name)
            try Data("fixture export".utf8).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-40)], ofItemAtPath: file.path)
        }
        let typedScanner = ExportFolderScanner()
        let typedFirst = typedScanner.scan(paths: [typed.path], now: now)
        let typedSecond = typedScanner.scan(paths: [typed.path], now: now.addingTimeInterval(21))
        require(typedFirst.count == 3 && typedSecond.count == 3, "only configured export formats may be listed")
        require(typedSecond.allSatisfy { $0.state == .stable },
                "video, audio and 3D export fixtures must remain stable, not falsely readable or finished")
        require(typedSecond.contains { $0.kind == .video } && typedSecond.contains { $0.kind == .audio }
                && typedSecond.contains { $0.kind == .other }, "type filters missed actual scanner outputs")
        require(!RenderKind.isSupportedExport("project.blend") && RenderKind.isSupportedExport("scene.glb"),
                "project sources must not be treated as exports")
        try (png + Data([0])).write(to: image)
        let changed = scanner.scan(paths: [directory.path], now: now.addingTimeInterval(7))
        require(changed.count == 1 && changed[0].state == .pending, "changed file must return to pending")
        require(changed[0].id != second[0].id, "changed bytes must not reuse preview identity")
        require(ShadowFolderScanner.validRemotePath("C:/renders/brut"), "valid Shadow folder rejected")
        require(!ShadowFolderScanner.validRemotePath("../rendus"), "relative Shadow path accepted")
        require(!ShadowFolderScanner.validRemotePath("C:/rendus/../private"), "traversal accepted")
        require(!ShadowFolderScanner.validRemotePath("C:/rendus';Stop-Process"), "unsafe path accepted")
        require(ShadowFolderScanner.validRemotePath("C:\\renders\\exports"), "Windows backslash path rejected")
        require(ShadowFolderScanner.validRemotePath("C:\\renders\\project-a\\final\\frame_0059.png"),
                "nested Shadow export path rejected")
        let remoteTime = ShadowFolderScanner.parseUTC("2026-10-11T23:39:05.4470284Z")
        require(remoteTime != nil && now.timeIntervalSince(remoteTime!) > 0,
                "real Shadow fractional UTC timestamp was not parsed")

        let corrupted = directory.appendingPathComponent("broken.png")
        try Data("not a PNG".utf8).write(to: corrupted)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-30)], ofItemAtPath: corrupted.path)
        let movie = directory.appendingPathComponent("clip.mov")
        try Data("unfinished video".utf8).write(to: movie)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-30)], ofItemAtPath: movie.path)
        try Data().write(to: directory.appendingPathComponent("empty.png"))
        let symlink = directory.appendingPathComponent("linked.png")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: image)
        let validationScanner = ExportFolderScanner()
        let check1 = validationScanner.scan(paths: [directory.path], now: now)
        let check2 = validationScanner.scan(paths: [directory.path], now: now.addingTimeInterval(25))
        require(check1.count == 3 && check2.count == 3, "empty/symlink/non-render file included")
        require(check2.first(where: { $0.filename == "broken.png" })?.state == .stable,
                "corrupt image falsely readable")
        require(check2.first(where: { $0.filename == "clip.mov" })?.state == .stable,
                "video without render completion signal falsely complete")

        let sample = RenderEntry(id: "folder", source: .macFolder, job: "frames",
                                 filename: "frame_0001.png", modified: now,
                                 state: .complete, path: image.path, previewURL: nil)
        let api = RenderEntry(id: "api", source: .macMonitor, job: "frames",
                              filename: "FRAME_0001.PNG", modified: now.addingTimeInterval(1),
                              state: .complete, path: nil, previewURL: "http://127.0.0.1/preview")
        let secondJob = RenderEntry(id: "api-other-job", source: .macMonitor, job: "other job",
                                    filename: api.filename, modified: api.modified,
                                    state: .complete, path: nil, previewURL: "http://127.0.0.1/other")
        require(RenderMerger.merge(folders: [], monitors: [api, secondJob]).count == 2,
                "different monitor jobs with the same filename and timestamp were hidden")
        require(RenderMerger.merge(folders: [sample], monitors: [api]).count == 2,
                "pathless monitor entry was merged with an unrelated same-name file")
        let mappedAPI = RenderEntry(id: api.id, source: api.source, job: api.job,
                                    filename: api.filename, modified: api.modified,
                                    state: api.state, path: image.path, previewURL: api.previewURL)
        let competingAPI = RenderEntry(id: secondJob.id, source: secondJob.source,
                                       job: secondJob.job, filename: secondJob.filename,
                                       modified: secondJob.modified, state: secondJob.state,
                                       path: image.path, previewURL: secondJob.previewURL)
        require(RenderMerger.merge(folders: [sample], monitors: [mappedAPI, competingAPI]).count == 3,
                "ambiguous monitor-to-folder association hid a render")
        require(RenderMerger.merge(folders: [sample], monitors: [mappedAPI]) == [sample],
                "same Mac render duplicated across sources")
        var pending = sample
        pending.state = .pending
        require(RenderMerger.merge(folders: [pending], monitors: [mappedAPI]) == [mappedAPI],
                "complete API preview should win over pending folder file")
        var otherTime = api
        otherTime = RenderEntry(id: "later", source: api.source, job: api.job,
                                filename: api.filename, modified: now.addingTimeInterval(10),
                                state: api.state, path: nil, previewURL: api.previewURL)
        require(RenderMerger.merge(folders: [sample], monitors: [otherTime]).count == 2,
                "distinct renders with same name were collapsed")
        require(ShadowListing.entries(monitor: [api], folders: [sample], remoteOnline: true,
                                      foldersConfigured: true) == [sample],
                "Shadow API and SSH listings must not double-count")
        require(ShadowListing.entries(monitor: [api], folders: [], remoteOnline: false,
                                      foldersConfigured: true) == [api],
                "offline Shadow folder scan must retain the API listing")

        let oldConfig = Data("{\"macFolders\":[],\"shadowFolders\":[\"C:/renders\"]}".utf8)
        var migrated = try JSONDecoder().decode(AppConfig.self, from: oldConfig)
        require(migrated.shadowFolders == ["C:/renders"] && migrated.dismissedMacFolders.isEmpty,
                "old config must migrate without losing Shadow folders")
        require(migrated.importNewMacMonitorFolders([directory.path]) == [directory.path],
                "new Mac monitor folder must be discovered")
        require(migrated.importNewMacMonitorFolders([directory.path]).isEmpty,
                "discovered folder must not be duplicated")
        migrated.removeMacFolder(directory.path)
        require(migrated.importNewMacMonitorFolders([directory.path]).isEmpty,
                "explicitly removed folder must stay removed")
        let roundTrip = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(migrated))
        require(roundTrip.dismissedMacFolders == [directory.path] && roundTrip.shadowFolders == ["C:/renders"],
                "config round-trip must preserve user choices")
        let finalJob = MacJob(id: "final", titre: "Project Atlas — RENDU FINAL r2", sous: nil,
                              total: 10, faites: 4, en_cours: ["frame_0005.png"], latest: [], times: [], proc: nil)
        require(RenderOrganization.project(for: sample, jobs: [finalJob], knownFolders: ["final": directory.path],
                                           labels: [:]) == "Project Atlas", "monitor title must identify project")
        require(RenderOrganization.isConfirmedFinal(sample, jobs: [finalJob], knownFolders: ["final": directory.path]),
                "explicit final job may group its exports")
        let rough = RenderEntry(id: "rough", source: .shadowFolder, job: "brut", filename: "frame.png",
                                modified: now, state: .pending, path: "C:/renders/project/brut/frame.png", previewURL: nil)
        require(!RenderOrganization.isConfirmedFinal(rough, jobs: [], knownFolders: [:]),
                "brut export must not be called final")
        require(RenderOrganization.project(for: rough, jobs: [], knownFolders: [:],
                                           labels: ["C:/renders/project/brut": "Project Atlas"]) == "Project Atlas",
                "configured project label must group Shadow exports")
        let dated = RenderEntry(id: "dated", source: .shadowFolder, job: "brut", filename: "frame.png",
                                modified: now, state: .stable,
                                path: "C:/renders/PROJECT_ALPHA_20261012/v002/brut/frame.png", previewURL: nil)
        require(RenderOrganization.project(for: dated, jobs: [], knownFolders: [:], labels: [:])
                    == "PROJECT_ALPHA_20261012", "project code must come verbatim from source path")

        require(RenderProgress(completed: 31, total: 240)?.percentLabel == "12.9 %", "true progress ratio incorrect")
        require(RenderProgress(completed: 31, total: 240)?.fraction == Double(31)/240, "fraction incorrect")
        for pair in [(0, 0), (-1, 240), (241, 240), (31, -1)] {
            require(RenderProgress(completed: pair.0, total: pair.1) == nil, "invalid counter produced percentage")
        }
        let noTotal = try JSONDecoder().decode(MacJob.self, from: Data(#"{"id":"unknown","titre":"Job","faites":31}"#.utf8))
        require(noTotal.progress == nil, "missing total must remain indeterminate")
        let noNumerator = try JSONDecoder().decode(MacJob.self, from: Data(#"{"id":"unknown","titre":"Job","total":240}"#.utf8))
        require(noNumerator.progress == nil, "missing numerator must remain indeterminate")
        require(RenderDate.parseOptional("bad") == nil && RenderDate.parseOptional(nil) == nil, "missing dates fabricated")
        require(RenderDate.parseOptional("2026-10-12T12:00:00Z") != nil, "UTC date not decoded")
        require(!RenderOrganization.isInside("/tmp/Project/file.png", root: "/tmp/project"), "Mac case-sensitive identity conflated")
        require(RenderOrganization.isInside("C:/PROJECT/file.png", root: "c:/project"), "Windows path identity incorrect")
        require(ShadowListing.entries(monitor: [], folders: [sample], remoteOnline: false, foldersConfigured: true) == [sample],
                "last known Shadow exports disappeared when both transports offline")
        let healthScanner = ExportFolderScanner()
        _ = healthScanner.scan(paths: [directory.path, directory.appendingPathComponent("missing").path], now: now)
        require(healthScanner.health.online && healthScanner.health.partial, "partial local folder failure hidden")
        _ = healthScanner.scan(paths: [directory.appendingPathComponent("missing").path], now: now)
        require(!healthScanner.health.online && healthScanner.health.isStale, "offline local folder failure hidden")

        let windowsFinal = RenderEntry(id: "final-windows", source: .shadowFolder, job: "final", filename: "x.png",
                                       modified: now, state: .pending, path: "C:\\renders\\FINAL\\x.png", previewURL: nil)
        require(RenderOrganization.isConfirmedFinal(windowsFinal, jobs: [], knownFolders: [:]), "Windows final marker ignored")
        let remoteScanner = ShadowFolderScanner()
        let remoteRecord: [String: Any] = ["root": "C:/exports", "path": "C:/exports/frame.png", "name": "frame.png",
                                           "bytes": 100, "modified": "2026-10-12T10:00:00Z"]
        let remotePayload = try JSONSerialization.data(withJSONObject: ["ok": true, "files": [remoteRecord, remoteRecord], "missing": []])
        let remoteFirst = remoteScanner.ingest(remotePayload, roots: ["C:/exports"], now: now)
        let remoteStable = remoteScanner.ingest(remotePayload, roots: ["C:/exports"], now: now.addingTimeInterval(21))
        require(remoteFirst.count == 1 && remoteFirst[0].state == .pending, "remote duplicate or first-observation completion")
        require(remoteStable.count == 1 && remoteStable[0].state == .stable, "remote stability must require second observation")
        let offlineEntries = remoteScanner.ingest(nil, roots: ["C:/exports"], now: now.addingTimeInterval(22))
        require(offlineEntries.count == 1 && remoteScanner.health.isStale && !remoteScanner.health.online,
                "remote last-good failure must remain stale")
        require(remoteScanner.ingest(nil, roots: ["C:/other"], now: now).isEmpty, "removed remote root resurrected from last-good cache")
        var invalidRemote = remoteRecord; invalidRemote["modified"] = "invalid"
        let invalidPayload = try JSONSerialization.data(withJSONObject: ["ok": true, "files": [invalidRemote], "missing": []])
        require(remoteScanner.ingest(invalidPayload, roots: ["C:/exports"], now: now).isEmpty, "remote date fabricated")
        invalidRemote = remoteRecord; invalidRemote["name"] = "source.blend"
        let sourcePayload = try JSONSerialization.data(withJSONObject: ["ok": true, "files": [invalidRemote], "missing": []])
        require(remoteScanner.ingest(sourcePayload, roots: ["C:/exports"], now: now).isEmpty, "remote project source misclassified as render")

        let sequenceJob = MacJob(id: "sequence", titre: "Sequence demo — export", sous: nil, total: 240, faites: 31,
                                 en_cours: [], latest: [], times: [], proc: nil, workType: .video)
        require(sample.fileMediaType == .image && RenderOrganization.workType(for: sample, jobs: [sequenceJob],
                knownFolders: ["sequence": directory.path], configured: [:]) == .video,
                "PNG video sequence must keep declared video work type")
        require(RenderOrganization.workType(for: sample, jobs: [sequenceJob], knownFolders: ["sequence": directory.path],
                                           configured: [directory.path: .image]) == .image, "user work category must take precedence")
        require(RenderOrganization.workType(for: sample, jobs: [], knownFolders: [:], configured: [:]) == nil,
                "file extension must not invent work category")
        let categoryConfig = AppConfig(macFolders: [directory.path], folderWorkTypes: [directory.path: .audio])
        let categoryRoundtrip = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(categoryConfig))
        require(categoryRoundtrip.folderWorkTypes[directory.path] == .audio, "declared work category lost in persistence")
        require(migrated.folderWorkTypes.isEmpty, "old config must not invent work categories")

        let renamedMonitor = RenderEntry(id: "rename", source: .macMonitor, job: "Changed display title", filename: "frame.png",
                                         modified: now, state: .stable, path: nil, previewURL: nil, monitorJobID: "sequence")
        require(RenderOrganization.projectID(for: sample, jobs: [sequenceJob], knownFolders: ["sequence": directory.path], labels: [:])
                == RenderOrganization.projectID(for: renamedMonitor, jobs: [sequenceJob], knownFolders: ["sequence": directory.path], labels: [:]),
                "renamed job and folder frames split stable identity")
        require(RenderOrganization.workType(for: renamedMonitor, jobs: [sequenceJob], knownFolders: [:], configured: [:]) == .video,
                "renamed job lost declared work type")

        let futureConfig = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"macFolders":["/tmp/chosen"],"shadowFolders":[],"folderWorkTypes":{"/tmp/chosen":"unknown-future-type"}}"#.utf8))
        require(futureConfig.macFolders == ["/tmp/chosen"] && futureConfig.folderWorkTypes.isEmpty,
                "unknown work type must not discard configured folders")

        require(RenderOrganization.projectID(for: rough, jobs: [], knownFolders: [:], labels: [:]) == "folder:c:/renders/project/brut",
                "Windows project identity must not depend on current Mac working directory")

        for index in 0..<100 {
            try png.write(to: directory.appendingPathComponent(String(format: "bulk_%03d.png", index)))
        }
        require(ExportFolderScanner().scan(paths: [directory.path], now: now).count == 80,
                "scan must bound large export directories")
        require(healthScanner.scan(paths: [directory.path], now: now).count == 80 && healthScanner.listingTruncated
                    && healthScanner.supportedFileCount > 80, "listing cap must be explicit")
        var health = SourceHealth()
        health.online = true
        health.partial = true
        require(health.label == "Partiel", "partial Shadow scan not visible")
        health.isStale = true
        require(health.label == "Données périmées", "stale online transport presented as fresh")
        print("ScannerTests: \(assertions) assertions passed")
    }
}
