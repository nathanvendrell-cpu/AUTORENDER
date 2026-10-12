import CryptoKit
import Darwin
import Foundation

private enum CollectorProcess {
    private static let lock = NSLock()
    private static var running: [UUID: Process] = [:]
    private static var cancelled = Set<UUID>()

    static func cancel(_ token: UUID) {
        lock.lock(); cancelled.insert(token); let process=running[token]; lock.unlock()
        if let process, process.isRunning { process.terminate() }
    }
    static func asyncRun(arguments: [String], timeout: TimeInterval) async -> Data? {
        let token=UUID()
        return await withTaskCancellationHandler(operation: {
            await Task.detached(priority:.utility) { run(arguments:arguments,timeout:timeout,token:token) }.value
        }, onCancel: { cancel(token) })
    }

    static func cancelAll() {
        lock.lock()
        let processes = Array(running.values)
        lock.unlock()
        for process in processes where process.isRunning { process.terminate() }
        let deadline = Date().addingTimeInterval(5)
        while processes.contains(where: { $0.isRunning }) && Date() < deadline {
            usleep(100_000)
        }
        for process in processes where process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    static func run(arguments: [String], timeout: TimeInterval, token: UUID) -> Data? {
        lock.lock(); let alreadyCancelled=cancelled.remove(token) != nil; lock.unlock()
        guard !alreadyCancelled else { return nil }
        defer { lock.lock(); cancelled.remove(token); lock.unlock() }
        let script = Bundle.main.url(forResource: "shadow_collector", withExtension: "py")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("shadow_collector.py")
        guard FileManager.default.fileExists(atPath: script.path) else { return nil }
        let python = FileManager.default.fileExists(atPath: "/opt/homebrew/bin/python3")
            ? "/opt/homebrew/bin/python3" : "/usr/bin/python3"
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("rendubar-collector-" + UUID().uuidString, isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let stdout = temporary.appendingPathComponent("stdout")
        let stderr = temporary.appendingPathComponent("stderr")
        guard FileManager.default.createFile(atPath: stdout.path, contents: nil),
              FileManager.default.createFile(atPath: stderr.path, contents: nil),
              let outHandle = try? FileHandle(forWritingTo: stdout),
              let errHandle = try? FileHandle(forWritingTo: stderr) else { return nil }
        defer { try? outHandle.close(); try? errHandle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [script.path] + arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outHandle
        process.standardError = errHandle
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }
        lock.lock()
        running[token] = process
        let cancelAfterLaunch=cancelled.contains(token)
        lock.unlock()
        if cancelAfterLaunch && process.isRunning { process.terminate() }
        defer {
            lock.lock()
            running.removeValue(forKey: token)
            cancelled.remove(token)
            lock.unlock()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if done.wait(timeout: .now() + 3) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = done.wait(timeout: .now() + 2)
            }
        }
        guard !process.isRunning, process.terminationStatus == 0 else { return nil }
        try? outHandle.synchronize()
        return try? Data(contentsOf: stdout)
    }
}

@MainActor
final class ShadowFolderScanner {
    private struct Stamp {
        let size: Int64
        let modified: Date
        let seenAt: Date
    }

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
        let data = await CollectorProcess.asyncRun(arguments:["scan","--roots-json",rootsJSON],timeout:25)
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
        let data = await CollectorProcess.asyncRun(arguments:["history","--roots-json",json],timeout:25)
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
        let result = await CollectorProcess.asyncRun(arguments:args,timeout:38)
        guard !Task.isCancelled else { return nil }
        guard let result,
              let object = try? JSONSerialization.jsonObject(with: result) as? [String: Any],
              object["ok"] as? Bool == true else { return nil }
        return try? Data(contentsOf: destination)
    }

    func cancel() { CollectorProcess.cancelAll() }

    nonisolated static func parseUTC(_ value: String) -> Date? {
        RenderDate.parseOptional(value)
    }
}

struct RemoteHistoryResult { let entries:[RenderEntry]; let coverage:String }
