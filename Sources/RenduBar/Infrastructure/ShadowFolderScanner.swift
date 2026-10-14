import Foundation
import CryptoKit

@MainActor
final class ShadowFolderScanner {
    private struct Stamp {
        let size: Int64
        let modified: Date
        let seenAt: Date
    }

    private var shutdownTask: Task<Void,Never>?
    private let fixtureHelperURL:URL?
    init(fixtureHelperURL:URL? = nil) { self.fixtureHelperURL=fixtureHelperURL }
    private var stamps: [String: Stamp] = [:]
    private var lastGood: [RenderEntry] = []
    private(set) var health = SourceHealth()

    nonisolated static func validRemotePath(_ path: String) -> Bool {
        let bytes = Array(path.utf8)
        guard bytes.count >= 4, bytes.count <= 390,
              (65...90).contains(bytes[0]) || (97...122).contains(bytes[0]),
              bytes[1] == 58, bytes[2] == 47 || bytes[2] == 92,
              !bytes.contains(where: { $0 < 32 || $0 == 127 }) else { return false }
        let parts = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/")
        return !parts.contains("..") && !path.contains("'") && !path.contains("\"")
            && !path.contains("`") && !path.contains("$") && !path.contains(";")
    }

    func scan(_ roots: [String]) async -> [RenderEntry] {
        guard let rootsData = try? JSONSerialization.data(withJSONObject: roots),
              let rootsJSON = String(data: rootsData, encoding: .utf8) else { return lastGood }
        lastGood = lastGood.filter { e in e.path.map { path in roots.contains { RenderOrganization.isInside(path, root: $0) } } ?? false }
        let data = await CollectorProcess.asyncRun(arguments:["scan","--roots-json",rootsJSON],timeout:25,fixtureHelperURL:fixtureHelperURL)
        guard !Task.isCancelled else { return lastGood }
        return ingest(data, roots: roots)
    }

    // Shared by live collection and deterministic transport-failure fixtures.
    func ingest(_ data: Data?, roots: [String], now: Date = Date()) -> [RenderEntry] {
        lastGood = lastGood.filter { e in e.path.map { path in roots.contains { RenderOrganization.isInside(path, root: $0) } } ?? false }
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["ok"] as? Bool == true,
              let files = object["files"] as? [[String: Any]] else {
            health.online = false
            health.isStale = true
            health.checkedAt = now
            health.message = "Shadow inaccessible ou dossier indisponible"
            return lastGood
        }
        let missing = object["missing"] as? [String] ?? []
        if missing.count == roots.count {
            health.online = false
            health.isStale = true
            health.checkedAt = now
            health.message = "Tous les dossiers Shadow sont introuvables"
            return lastGood
        }
        health.online = true
        health.isStale = false
        health.observedAt = now
        health.partial = !missing.isEmpty
        health.checkedAt = now
        health.lastGoodAt = now
        health.message = missing.isEmpty ? "Dossiers Shadow vérifiés · \(files.count) fichiers" : "\(missing.count) dossier(s) Shadow introuvable(s)"
        var entries: [RenderEntry] = []
        var liveIDs = Set<String>()
        for file in files {
            guard let root = file["root"] as? String,
                  let path = file["path"] as? String,
                  let name = file["name"] as? String,
                  let bytes = file["bytes"] as? NSNumber,
                  let rawDate = file["modified"] as? String,
                  Self.validRemotePath(path), bytes.int64Value > 0, RenderKind.isSupportedExport(name),
                  roots.contains(where: { RenderOrganization.isInside(path, root: $0) }),
                  let modified = Self.parseUTC(rawDate) else { continue }
            let id = "shadow-folder:" + path.lowercased().replacingOccurrences(of: "\\", with: "/")
                + ":\(bytes.int64Value):\(rawDate)"
            liveIDs.insert(id)
            let previous = stamps[id]
            let unchanged = previous?.size == bytes.int64Value && previous?.modified == modified
            let seenAt = unchanged ? (previous?.seenAt ?? now) : now
            stamps[id] = Stamp(size: bytes.int64Value, modified: modified, seenAt: seenAt)
            let dwell = RenderKind.classify(name) == .image ? 8.0 : 20.0
            let complete = unchanged && now.timeIntervalSince(seenAt) >= dwell
                && now.timeIntervalSince(modified) >= dwell
            entries.append(RenderEntry(id: id, source: .shadowFolder,
                                       job: (root as NSString).lastPathComponent,
                                       filename: name, modified: modified,
                                       state: complete ? .stable : .pending,
                                       path: path, previewURL: nil))
        }
        stamps = stamps.filter { liveIDs.contains($0.key) }
        var seen = Set<String>()
        entries = entries.filter { seen.insert($0.id).inserted }
        lastGood = entries.sorted { $0.modified > $1.modified }.prefix(80).map { $0 }
        return lastGood
    }

    func history(_ roots: [String]) async -> RemoteHistoryResult? {
        guard let encoded = try? JSONSerialization.data(withJSONObject:roots), let json = String(data:encoded,encoding:.utf8) else { return nil }
        let data = await CollectorProcess.asyncRun(arguments:["history","--roots-json",json],timeout:25,fixtureHelperURL:fixtureHelperURL)
        guard !Task.isCancelled, let data, let object = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
              object["ok"] as? Bool == true, let files = object["files"] as? [[String:Any]] else { return nil }
        var entries:[RenderEntry] = []; var seen=Set<String>()
        for file in files {
            guard let path=file["path"] as? String, let name=file["name"] as? String, let bytes=file["bytes"] as? NSNumber,
                  let raw=file["modified"] as? String, let modified=RenderDate.parseOptional(raw), Self.validRemotePath(path), bytes.int64Value>0,
                  RenderKind.isSupportedExport(name), roots.contains(where:{ RenderOrganization.isInside(path,root:$0) }) else { continue }
            let id="shadow-folder:" + path.lowercased().replacingOccurrences(of:"\\",with:"/") + ":\(bytes.int64Value):\(raw)"
            guard seen.insert(id).inserted else { continue }
            entries.append(RenderEntry(id:id,source:.shadowFolder,job:"Dossier Shadow suivi",filename:name,modified:modified,state:.pending,path:path,previewURL:nil))
        }
        let missing=object["missing"] as? [String] ?? []
        return RemoteHistoryResult(entries:entries,coverage:missing.isEmpty ? "Inventaire distant du scope demandé · validation fichiers non certifiée" : "Inventaire distant partiel · dossiers indisponibles")
    }

    func preview(_ path: String, roots: [String], id: String) async -> Data? {
        guard let rootsData = try? JSONSerialization.data(withJSONObject: roots),
              let rootsJSON = String(data: rootsData, encoding: .utf8) else { return nil }
        let hash = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        let destination = RenduStorage.root.appendingPathComponent("Previews/" + hash + ".jpg")
        let args = ["preview", "--roots-json", rootsJSON, "--path", path, "--output", destination.path]
        let result = await CollectorProcess.asyncRun(arguments:args,timeout:38,fixtureHelperURL:fixtureHelperURL)
        guard !Task.isCancelled else { return nil }
        guard let result,
              let object = try? JSONSerialization.jsonObject(with: result) as? [String: Any],
              object["ok"] as? Bool == true else { return nil }
        return try? Data(contentsOf: destination)
    }

    func cancel() {
        CollectorProcess.requestCancelAll()
        shutdownTask=Task.detached(priority:.utility) { CollectorProcess.waitForExit() }
    }
    func waitForShutdown() async { await shutdownTask?.value }

    nonisolated static func parseUTC(_ value: String) -> Date? {
        RenderDate.parseOptional(value)
    }
}

struct RemoteHistoryResult { let entries:[RenderEntry]; let coverage:String }
