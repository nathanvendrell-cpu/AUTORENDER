import Foundation

@main enum ProviderRootCollisionProbe {
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("autoren-provider-root-collision-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let output = root.appendingPathComponent("renders")
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        let now = Date()
        let identity = NativeProcessIdentity(
            pid: 4242,
            birthSeconds: UInt64(now.timeIntervalSince1970) - 10,
            birthMicroseconds: 123,
            executable: "/Applications/Blender.app/Contents/MacOS/Blender"
        )
        var observation = NativeRenderObservation(identity: identity, producer: "Blender", observedAt: now)
        observation.outputRoot = output.path
        observation.outputPattern = output.appendingPathComponent("frame_####.png").path
        observation.renderCommand = true

        let provider = MacJob(id: "provider", titre: "Provider job", sous: nil, total: 1, faites: 0,
                              en_cours: [], latest: [], times: [], proc: nil)
        var health = SourceHealth()
        health.online = true
        health.observedAt = now
        var input = RenderCatalogInput(
            revision: 1,
            macJobs: [provider],
            shadow: nil,
            declaration: nil,
            config: AppConfig(),
            knownFolders: [provider.id: output.path],
            entries: [],
            macEntries: [],
            folderEntries: [],
            shadowEntries: [],
            shadowFolderEntries: [],
            macHealth: health,
            shadowHealth: SourceHealth(),
            folderHealth: health,
            remoteHealth: SourceHealth()
        )
        input.nativeObservations = [observation]

        let service = RenderCatalogService(root: root.appendingPathComponent("catalogue"))
        guard let snapshot = await service.build(input) else {
            fatalError("catalogue build returned nil")
        }
        precondition(snapshot.jobs.contains { $0.id == "mac:provider" }, "provider job missing")
        precondition(snapshot.jobs.contains { $0.id == identity.jobID && $0.activity == .unknown },
                     "distinct native candidate suppressed or promoted by provider root")
        print("PASS: distinct native PID/birth/executable candidate retained unknown beside provider sharing only its root")
    }
}
