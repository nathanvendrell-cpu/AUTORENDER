import Foundation

@main
enum DashboardSourceProbe {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let shadow = try JSONDecoder().decode(ShadowResponse.self, from: Data(contentsOf: root.appendingPathComponent("shadow-payload.json")))
        let mac = try JSONDecoder().decode(MacResponse.self, from: Data(contentsOf: root.appendingPathComponent("mac-payload.json")))
        let page = try Data(contentsOf: root.appendingPathComponent("monitor-page.html"))
        guard let declaration = ShadowDashboardDeclaration.parse(page, sourceURL: "http://127.0.0.1:4420/"), declaration.matches(shadow) else {
            throw NSError(domain: "DeclaredSourceMatch", code: 1)
        }
        var health = SourceHealth(); health.online = true; health.observedAt = RenderDate.parseOptional(shadow.now)
        health.isStale = health.observedAt.map { Date().timeIntervalSince($0) > 45 } ?? true
        let output = RenderDashboard.shadow(shadow, health: health, declaration: declaration)
        guard output.rawProgress != nil, output.postProgress != nil, output.eta == nil,
              shadow.blender == 0, output.activity == .resumeRequired else { throw NSError(domain: "StoppedDashboard", code: 2) }
        print("Source snapshot: \(shadow.now ?? "unknown"), fresh at probe: \(output.isFresh)")
        print("Shadow: \(output.rawProgress!.countLabel) raw; \(output.postProgress!.countLabel) post; \(output.activityLabel); future ETA absent")
        print("Declared page provenance: \(declaration.sourceURL), SHA256 \(declaration.sha256), \(declaration.planTotals.count) plans")
        print("GPU data provided: \(output.gpu != nil); tasks Running: \(output.tasks.filter { $0.state == "Running" }.count)")
        let jobs = mac.jobs.map { RenderDashboard.mac($0, health: health, projectID: $0.projectID ?? "job:" + $0.id, workType: $0.workType) }
        print("Mac: \(jobs.count) separate versions; counters \(jobs.map { $0.rawProgress?.countLabel ?? "indeterminate" }.joined(separator: ", "))")
        if CommandLine.arguments.count > 2 {
            let config = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
            let linked = (jobs + [output]).map { RenderDashboard.applyingProjectLink($0, links: config.dashboardProjectLinks) }
            let projects = RenderDashboard.projects(linked)
            guard projects.count == 2, projects.contains(where: { $0.jobs.count == 3 && $0.jobs.allSatisfy { $0.source == .macMonitor } }) else {
                throw NSError(domain: "PrivateProjectLinks", code: 3)
            }
            print("Private config grouping: \(projects.count) projects, \(projects.map { $0.title + ": " + String($0.jobs.count) + " job(s)" }.joined(separator: "; "))")
            print("Labels configured: \(config.folderProjects.count); original job IDs preserved, no summed version percentage")
        }
        print("Project IDs declared by API: \(mac.jobs.filter { $0.projectID != nil }.count); user configuration or source metadata required for common project selection")
    }
}
