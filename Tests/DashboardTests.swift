import Foundation

@main
enum DashboardTests {
    static var count = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        count += 1; precondition(value(), message)
    }
    static func main() throws {
        let at = RenderDate.parse("2026-10-12T12:00:00Z")
        var health = SourceHealth(); health.online = true; health.observedAt = at
        let times = ["2026-10-12T11:57:00Z", "2026-10-12T11:58:00Z", "2026-10-12T11:59:00Z"]
        let stopped = MacJob(id: "version1", titre: "Demo — v1", sous: "Plan déclaré", total: 240, faites: 80,
                             en_cours: ["frame.png"], latest: [], times: times, proc: nil, workType: .video, projectID: "demo")
        let stoppedView = RenderDashboard.mac(stopped, health: health, projectID: "project:demo", workType: .video)
        check(stoppedView.isFresh && stoppedView.activity == .resumeRequired, "fresh incomplete stopped job must be resumable")
        check(stoppedView.eta == nil && stoppedView.historicalMedianSeconds == 60, "stopped job must not project future ETA")
        check(stoppedView.sampledOutputsLastHour == 3 && stoppedView.lastActivity == RenderDate.parse(times.last), "timing sample lost")
        let process = MacProcess(cpu: "12", ram_mo: 2800, duree: "00:20:00")
        let active = MacJob(id: "version2", titre: "Demo — v2", sous: nil, total: 240, faites: 31,
                            en_cours: [], latest: [], times: times, proc: process, workType: .video, projectID: "demo")
        let activeView = RenderDashboard.mac(active, health: health, projectID: "project:demo", workType: .video)
        check(activeView.activity == .running && activeView.eta != nil, "fresh process permits qualified ETA")
        check(activeView.rawProgress?.percentLabel == "12.9 %", "actual ratio changed")
        let projects = RenderDashboard.projects([stoppedView, activeView])
        check(projects.count == 1 && projects[0].jobs.count == 2, "explicit project must retain both distinct versions")
        check(Set(projects[0].jobs.map(\.id)).count == 2 && projects[0].jobs.map { $0.rawProgress!.total } == [240,240], "versions aggregated or collapsed")
        health.isStale = true
        let stale = RenderDashboard.mac(active, health: health, projectID: "project:demo", workType: .video)
        check(stale.eta == nil && stale.historicalETA != nil && !stale.isFresh, "stale active measurement must have historical ETA only")
        check(stale.activityLabel.contains("dernier relevé"), "historical activity unqualified")
        health.isStale = false
        let missingProcess = try JSONDecoder().decode(MacJob.self, from: Data(#"{"id":"missing","titre":"Demo","total":240,"faites":80}"#.utf8))
        check(RenderDashboard.mac(missingProcess, health: health, projectID: "missing", workType: nil).activity == .unknown, "absent process must not imply stopped")
        let missingTotal = MacJob(id: "unknown-total", titre: "Demo", sous: nil, total: 0, faites: 31, en_cours: [], latest: [], times: times, proc: process)
        let indeterminate = RenderDashboard.mac(missingTotal, health: health, projectID: "unknown", workType: nil)
        check(indeterminate.rawProgress == nil && indeterminate.eta == nil, "missing total must not produce ratio/ETA")
        var historical = stopped; historical.eta = "2026-10-12T13:00:00Z"
        let historicalView = RenderDashboard.mac(historical, health: health, projectID: "demo", workType: nil)
        check(historicalView.eta == nil && historicalView.historicalETA != nil, "reported ETA of stopped job promoted to future ETA")
        let page = #"<h1>Demo project</h1><script>const TOTAL=12; const PLANS=[["P1",5,1],["P2",7,2]]; fetch('api/status'); s.brut/TOTAL; s.post/TOTAL; t.name.replace("Demo_v1_","Tâche ");</script>"#
        let declaration = ShadowDashboardDeclaration.parse(Data(page.utf8), sourceURL: "http://127.0.0.1:4420", checkedAt: at)
        check(declaration?.total == 12 && declaration?.planTotals["P2"] == 7, "declared page total/plan parsing failed")
        check(declaration?.sha256.count == 64, "declaration provenance missing")
        var shadow = try JSONDecoder().decode(ShadowResponse.self, from: Data(#"{"ok":true,"now":"2026-10-12T12:00:00Z","brut":7,"post":3,"blender":0,"tasks":[{"name":"Demo_v1_E1","state":"Ready"}],"plans":{"P1":2},"gpu":"11, 900, 16380, 39"}"#.utf8))
        let noDeclaration = RenderDashboard.shadow(shadow, health: health, declaration: nil)
        check(noDeclaration.activity == .stopped && noDeclaration.rawProgress == nil && noDeclaration.eta == nil, "Ready/0 Blender cannot fabricate total or running state")
        let declared = RenderDashboard.shadow(shadow, health: health, declaration: declaration)
        check(declared.activity == .resumeRequired && declared.rawProgress?.total == 12 && declared.postProgress?.total == 12, "explicit declaration must enable incomplete resume state")
        check(declared.eta == nil && declared.totalProvenance?.contains("sha256") == true, "stopped Shadow ETA or unproven denominator")
        check(declared.plans.first { $0.id == "P2" }?.completed == nil, "missing plan count replaced by zero")
        check(declared.gpu?.usedMiB == 900 && declared.gpu?.utilizationPercent == 11, "GPU measurement parsing failed")
        let readyOnly = try JSONDecoder().decode(ShadowResponse.self, from: Data(#"{"ok":true,"tasks":[{"name":"Demo_v1_E1","state":"Ready"}],"brut":7,"post":3}"#.utf8))
        check(RenderDashboard.shadow(readyOnly, health: health, declaration: declaration).activity == .unknown, "Ready without Blender measurement invented process state")
        let mismatchPage = page.replacingOccurrences(of: "Demo_v1_", with: "Other_v2_")
        let mismatch = ShadowDashboardDeclaration.parse(Data(mismatchPage.utf8), sourceURL: "http://127.0.0.1:4420", checkedAt: at)
        check(RenderDashboard.shadow(shadow, health: health, declaration: mismatch).rawProgress == nil, "unrelated project declaration reused")
        check(ShadowDashboardDeclaration.parse(Data(page.replacingOccurrences(of: "TOTAL=12", with: "TOTAL=13").utf8), sourceURL: "local") == nil, "incoherent declared plan totals accepted")
        shadow.total = 12; shadow.times = times
        let apiDeclared = RenderDashboard.shadow(shadow, health: health, declaration: nil)
        check(apiDeclared.rawProgress?.total == 12 && apiDeclared.postProgress?.total == 12, "structured API total ignored")
        check(RenderGPUMetrics("invalid") == nil, "invalid GPU promoted to metrics")
        let longAgo = ["2026-10-12T10:00:00Z", "2026-10-12T10:01:00Z"]
        let stalled = MacJob(id: "stalled", titre: "Demo", sous: nil, total: 240, faites: 80, en_cours: [], latest: [], times: longAgo, proc: process)
        check(RenderDashboard.mac(stalled, health: health, projectID: "stalled", workType: nil).eta == nil,
              "fresh process with stale output cadence must not project ETA")
        let previews = (0..<3).map { index in RenderEntry(id: String(index), source: .macMonitor, job: "Demo", filename: "f.png",
            modified: at.addingTimeInterval(Double(index)), state: .pending, path: nil, previewURL: nil) }
        check(RenderDashboard.mac(active, health: health, projectID: "demo", workType: nil, previews: previews).previewEntries.count == 2,
              "dashboard must bound previews to two")
        let linkConfig = AppConfig(dashboardProjectLinks: ["mac:version1": "Declared project"])
        let migratedLinks = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(linkConfig))
        check(migratedLinks.dashboardProjectLinks["mac:version1"] == "Declared project", "private grouping links not persisted")
        var linked = activeView; linked.projectTitle = "Declared project"
        let linkedProject = RenderDashboard.projects([linked])[0]
        check(linkedProject.title == "Declared project" && linkedProject.legacyIDs.contains("job:version2"), "display label or legacy selection lost")
        let folderSummary = RenderProjectSummary(title: "Chosen folder", entries: previews, workType: nil, id: "folder:chosen")
        let fallback = RenderDashboard.folder(folderSummary, health: health)
        check(fallback.rawProgress == nil && fallback.activity == .unknown && fallback.previewEntries.count == 2,
              "folder without monitor must remain visible without invented totals/process")
        let linkedView = RenderDashboard.applyingProjectLink(activeView, links: [activeView.id: "Chosen project"])
        check(linkedView.id == activeView.id && linkedView.projectID == "label:Chosen project" && linkedView.rawProgress == activeView.rawProgress,
              "explicit link must preserve job identity and version counters")
        let scopedFolder = RenderEntry(id: "scoped", source: .macFolder, job: "Same title", filename: "frame.png", modified: at,
                                      state: .stable, path: "/tmp/versionA/frame.png", previewURL: nil)
        let foreignFolder = RenderEntry(id: "foreign", source: .macFolder, job: "Same title", filename: "frame.png", modified: at,
                                       state: .stable, path: "/tmp/versionB/frame.png", previewURL: nil)
        let scopedMonitor = RenderEntry(id: "scoped-api", source: .macMonitor, job: "Same title", filename: "other.png", modified: at,
                                       state: .stable, path: nil, previewURL: nil, monitorJobID: "A")
        let foreignMonitor = RenderEntry(id: "foreign-api", source: .macMonitor, job: "Same title", filename: "other.png", modified: at,
                                        state: .stable, path: nil, previewURL: nil, monitorJobID: "B")
        let scopedHistory = RenderDashboard.macHistory(jobID: "A", root: "/tmp/versionA", folders: [scopedFolder,foreignFolder], monitors: [scopedMonitor,foreignMonitor])
        check(Set(scopedHistory.map(\.id)) == ["scoped","scoped-api"], "same-title versions leaked into selected-job history")
        let currentFeed = RenderEntry(id: "current-feed", source: .shadowFolder, job: "Same project", filename: "frame.png", modified: at,
                                      state: .stable, path: "C:/project/versionA/brut/frame.png", previewURL: nil)
        let foreignFeed = RenderEntry(id: "other-version", source: .shadowFolder, job: "Same project", filename: "frame.png", modified: at,
                                      state: .stable, path: "C:/project/versionB/brut/frame.png", previewURL: nil)
        check(RenderDashboard.shadowHistory(roots: ["C:/project/versionA/brut"], folders: [currentFeed,foreignFeed], monitors: []).map(\.id) == ["current-feed"],
              "same-project Shadow versions leaked across feed history")
        let boundConfig = AppConfig(dashboardJobFolders: ["shadow:feed_": ["C:/project/versionA/brut"]])
        let boundRoundtrip = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(boundConfig))
        check(boundRoundtrip.dashboardJobFolders == boundConfig.dashboardJobFolders, "exact private job-folder binding lost")
        print("DashboardTests: \(count) assertions passed")
    }
}
