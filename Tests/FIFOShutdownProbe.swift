import Foundation
import Darwin

@main enum FIFOShutdownProbe {
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("autoren-fifo-cancel-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let storeRoot = root.appendingPathComponent("preferences")
        let outputRoot = root.appendingPathComponent("render-output")
        try fm.createDirectory(at: storeRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        let configURL = storeRoot.appendingPathComponent("config.json")
        try JSONEncoder().encode(AppConfig()).write(to: configURL)

        let fifo = root.appendingPathComponent("registry.fifo")
        guard mkfifo(fifo.path, 0o600) == 0 else { throw POSIXError(.EIO) }
        let registry = root.appendingPathComponent("monitor-jobs.json")
        try fm.createSymbolicLink(at: registry, withDestinationURL: fifo)

        let initial=try Data(contentsOf:configURL)
        let payload = try JSONSerialization.data(withJSONObject: [["id": "cancelled", "dossier": outputRoot.path]])
        let writer = DispatchWorkItem {
            let descriptor = open(fifo.path, O_WRONLY|O_NONBLOCK)
            guard descriptor >= 0 else { return }
            payload.withUnsafeBytes { bytes in
                if let address = bytes.baseAddress { _ = write(descriptor, address, bytes.count) }
            }
            close(descriptor)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(450), execute: writer)

        let worker = MacMonitorRegistryWorker()
        let started = Date()
        let task = Task { await worker.reconcile(registry: registry, store: RenderConfigStore(root: storeRoot), writable: true) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let result = await task.value
        let elapsed = Date().timeIntervalSince(started)
        precondition(writer.wait(timeout:.now()+1) == .success,"bounded writer not reaped")

        let persisted = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: configURL))
        let backups = try fm.contentsOfDirectory(at: storeRoot, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("config.before-preference-change-") }
        precondition(elapsed < 0.35,"nonregular registry waits on FIFO")
        precondition(result.added.isEmpty && result.issue != nil,"nonregular registry accepted")
        let unchanged=try Data(contentsOf:configURL)==initial
        precondition(persisted.macFolders.isEmpty && unchanged,"cancelled read mutates config")
        precondition(backups.isEmpty,"cancelled read creates backup")
        print("PASS: FIFO rejected in \(String(format: "%.3f", elapsed))s; cancelled reconcile preserves config bytes and zero backups")
    }
}
