import Foundation

@main
enum ReadOnlySourceSmoke {
    @MainActor static func main() async throws {
        let config = RenduStorage.load("config.json", as: AppConfig.self) ?? AppConfig.bootstrap()
        let local = ExportFolderScanner()
        let first = local.scan(paths: config.macFolders)
        print("Mac folders: \(config.macFolders.count), files: \(first.count), online: \(local.health.online), partial: \(local.health.partial), capped: \(local.listingTruncated)")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:4420/api/mac")!)
        request.timeoutInterval = 10
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let payload = try JSONDecoder().decode(MacResponse.self, from: data)
        guard payload.ok else { throw URLError(.badServerResponse) }
        print("Mac API: \(payload.jobs.count) jobs; source timestamp present: \(RenderDate.parseOptional(payload.now) != nil)")
        for (index, job) in payload.jobs.enumerated() { print("Job \(index): \(job.progress?.countLabel ?? "unknown") · \(job.progress?.percentLabel ?? "indeterminate") ; workType declared: \(job.workType != nil)") }
        let remote = ShadowFolderScanner()
        defer { remote.cancel() }
        guard !config.shadowFolders.isEmpty else { print("Shadow folders: SKIP no configured roots"); return }
        let entries = await remote.scan(config.shadowFolders)
        print("Shadow folders: \(config.shadowFolders.count), files: \(entries.count), online: \(remote.health.online), partial: \(remote.health.partial), stale: \(remote.health.isStale)")
        guard remote.health.online else { throw URLError(.cannotConnectToHost) }
        // No preview cache write, UI, playback or source mutation.
    }
}
