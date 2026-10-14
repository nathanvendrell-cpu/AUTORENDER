import Foundation
import CryptoKit

enum RenderActivity: String, Codable {
    case running = "En cours"
    case stopped = "Arrêté"
    case resumeRequired = "À reprendre"
    case countsReached = "Sorties comptées"
    case unknown = "Activité inconnue"
}

struct RenderDashboardPlan: Identifiable, Codable {
    let id: String
    let completed: Int?
    let total: Int
    let team: Int?
    var progress: RenderProgress? { completed.flatMap { RenderProgress(completed: $0, total: total) } }
}

struct RenderGPUMetrics: Codable {
    let utilizationPercent: Double
    let usedMiB: Double
    let totalMiB: Double
    let temperatureCelsius: Double
    init?(_ raw: String?) {
        guard let raw else { return nil }
        let values = raw.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard values.count == 4, values.allSatisfy(\.isFinite), (0...100).contains(values[0]),
              values[1] >= 0, values[2] > 0, values[1] <= values[2] else { return nil }
        utilizationPercent = values[0]; usedMiB = values[1]; totalMiB = values[2]; temperatureCelsius = values[3]
    }
}

struct ShadowDashboardDeclaration: Codable {
    let title: String
    let total: Int
    let planTotals: [String: Int]
    let planTeams: [String: Int]
    let taskPrefix: String
    let sourceURL: String
    let sha256: String
    let checkedAt: Date

    // Parse only the declared JSON array / integer literals, never execute JavaScript.
    static func parse(_ data: Data, sourceURL: String, checkedAt: Date = Date()) -> Self? {
        guard let html = String(data: data, encoding: .utf8),
              html.contains("api/status"), html.contains("s.brut/TOTAL"), html.contains("s.post/TOTAL") else { return nil }
        func capture(_ pattern: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let range = Range(match.range(at: 1), in: html) else { return nil }
            return String(html[range])
        }
        guard let title = capture(#"<h1[^>]*>([^<]+)</h1>"#),
              let literal = capture(#"const\s+TOTAL\s*=\s*([0-9]+)\s*;"#), let total = Int(literal), total > 0,
              let plansJSON = capture(#"const\s+PLANS\s*=\s*(\[.*?\])\s*;"#),
              let rows = try? JSONSerialization.jsonObject(with: Data(plansJSON.utf8)) as? [[Any]],
              let prefix = capture(#"\.name\.replace\("([^"]+)","Tâche "#), !prefix.isEmpty else { return nil }
        var totals: [String: Int] = [:]; var teams: [String: Int] = [:]
        for row in rows {
            guard row.count == 3, let name = row[0] as? String, !name.isEmpty,
                  let count = row[1] as? Int, count > 0, count <= total, totals[name] == nil,
                  let team = row[2] as? Int else { return nil }
            totals[name] = count; teams[name] = team
        }
        // This validates the declared total; it does not infer one from a sum.
        var sum = 0
        for count in totals.values {
            let addition = sum.addingReportingOverflow(count)
            guard !addition.overflow else { return nil }
            sum = addition.partialValue
        }
        guard !totals.isEmpty, sum == total else { return nil }
        return Self(title: title, total: total, planTotals: totals, planTeams: teams, taskPrefix: prefix,
                    sourceURL: sourceURL, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), checkedAt: checkedAt)
    }

    func matches(_ response: ShadowResponse) -> Bool {
        guard let tasks = response.tasks, !tasks.isEmpty, tasks.allSatisfy({ $0.name.hasPrefix(taskPrefix) }),
              (response.plans ?? [:]).keys.allSatisfy({ planTotals[$0] != nil }) else { return false }
        return true
    }
}

enum RenderTaskQualification: String, Codable {
    case nativeRenderCommand, nativeProductionContract, attestedShadowRun
}

struct RenderDashboardJob: Identifiable, Codable {
    var id: String
    let title: String
    var projectID: String
    let source: RenderSource
    var workType: RenderWorkType?
    let rawCount: Int?
    let postCount: Int?
    let rawProgress: RenderProgress?
    let postProgress: RenderProgress?
    let totalProvenance: String?
    let activity: RenderActivity
    var isFresh: Bool
    let observedAt: Date?
    let lastActivity: Date?
    let historicalMedianSeconds: Double?
    let sampledOutputsLastHour: Int?
    var eta: Date?
    var historicalETA: Date?
    let process: MacProcess?
    let gpu: RenderGPUMetrics?
    let gpuRaw: String?
    let plans: [RenderDashboardPlan]
    let tasks: [ShadowTask]
    let stageDescription: String?
    var previewEntries: [RenderEntry]
    var projectTitle: String? = nil
    var workID: String? = nil
    var versionID: String? = nil
    var workTitle: String? = nil
    var versionLabel: String? = nil
    var baseProjectID: String? = nil
    var sourceWorkID: String? = nil
    var sourceVersionID: String? = nil
    var contextIsSourceDeclared: Bool { sourceWorkID != nil || sourceVersionID != nil }
    var contextProvenance = "Job isolé · lien métier non déclaré"
    var openTargets: [RenderFolderTarget] = []
    var latestOutput: RenderEntry? = nil
    var revealURL: URL? = nil
    var archivedAt: Date? = nil
    var isArchived: Bool { archivedAt != nil }
    var isTerminalCounted: Bool {
        guard activity == .countsReached, let rawProgress, rawProgress.completed == rawProgress.total else { return false }
        if source.isShadow { return postProgress.map { $0.completed == $0.total } ?? false }
        return postProgress.map { $0.completed == $0.total } ?? true
    }
    var canArchive: Bool { isFresh && !retainedHistorical && isTerminalCounted && !isArchived }
    var retainedHistorical = false
    var estimatedRemainingSeconds: Double? = nil
    // Task qualification and recent output progression are distinct from GPU utilization.
    var taskQualification: RenderTaskQualification? = nil
    var progressObservedAt: Date? = nil
    var isDetectedActiveRender: Bool {
        isFresh && !retainedHistorical && !isArchived && activity == .running && taskQualification != nil && !isTerminalCounted
    }
    var isFinishedRender: Bool { !isArchived && isTerminalCounted }
    func hasRecentProgress(at now: Date = Date()) -> Bool {
        guard let observed=progressObservedAt else {return false}
        return now.timeIntervalSince(observed)>=0 && now.timeIntervalSince(observed)<=20
    }


    var activityLabel: String { isFresh ? activity.rawValue : activity.rawValue + " · dernier relevé" }
}

struct RenderDashboardProject: Identifiable, Codable {
    let id: String
    let title: String
    let jobs: [RenderDashboardJob]
    var legacyIDs: [String] {
        jobs.flatMap { job -> [String] in
            if job.id.hasPrefix("mac:") { return ["job:" + String(job.id.dropFirst(4))] }
            if job.id.hasPrefix("shadow:") { return ["source:shadow", "declared-shadow:" + String(job.id.dropFirst(7))] }
            return []
        }
    }
    var openTargets: [RenderFolderTarget] {
        var seen=Set<String>()
        return jobs.flatMap(\.openTargets).filter { seen.insert($0.id).inserted }
    }
    // No aggregated percentage: each version retains its own numerator / denominator.
}

enum RenderDashboard {
    static func mac(_ job: MacJob, health: SourceHealth, projectID: String, workType: RenderWorkType?,
                    previews: [RenderEntry] = []) -> RenderDashboardJob {
        let fresh = health.online && !health.isStale
        let timing = RenderTiming(times: job.times, at: health.observedAt)
        let progress = job.progress
        let activity: RenderActivity
        if job.proc != nil { activity = .running }
        else if !job.processReported { activity = .unknown }
        else if let progress, progress.completed == progress.total { activity = .countsReached }
        else if progress != nil { activity = .resumeRequired }
        else { activity = .stopped }
        let projection = estimatedDate(progress: progress, timing: timing, observedAt: health.observedAt, activity: activity)
        return RenderDashboardJob(id: "mac:" + job.id, title: job.titre, projectID: projectID, source: .macMonitor,
            workType: workType, rawCount: job.faites >= 0 ? job.faites : nil, postCount: nil, rawProgress: progress, postProgress: nil,
            totalProvenance: progress == nil ? nil : "api/mac · job.total", activity: activity, isFresh: fresh,
            observedAt: health.observedAt, lastActivity: timing.lastActivity, historicalMedianSeconds: timing.medianSeconds,
            sampledOutputsLastHour: timing.sampledOutputsLastHour, eta: fresh && activity == .running ? projection : nil,
            historicalETA: fresh && activity == .running ? nil : (RenderDate.parseOptional(job.eta) ?? projection),
            process: job.proc, gpu: nil, gpuRaw: nil, plans: [], tasks: [], stageDescription: job.sous,
            previewEntries: Array(previews.sorted { $0.modified > $1.modified }.prefix(2)))
    }

    static func shadow(_ response: ShadowResponse, health: SourceHealth, declaration: ShadowDashboardDeclaration?,
                       previews: [RenderEntry] = []) -> RenderDashboardJob {
        let declared = declaration.flatMap { $0.matches(response) ? $0 : nil }
        let rawTotal = response.rawTotal ?? response.total ?? declared?.total
        let postTotal = response.postTotal ?? response.total ?? declared?.total
        let raw = response.brut.flatMap { n in rawTotal.flatMap { RenderProgress(completed: n, total: $0) } }
        let post = response.post.flatMap { n in postTotal.flatMap { RenderProgress(completed: n, total: $0) } }
        let fresh = health.online && !health.isStale
        let timeline = (response.times?.isEmpty == false ? response.times : response.latest?.compactMap(\.t)) ?? []
        let timing = RenderTiming(times: timeline, at: health.observedAt)
        // Legacy Shadow payload has no job/run/root/PID-birthtime attribution.
        // Global process counts must not claim per-job running/stopped/completion.
        let activity: RenderActivity = .unknown
        let projection = estimatedDate(progress: raw, timing: timing, observedAt: health.observedAt, activity: activity)
        let plans = (declared?.planTotals ?? [:]).sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }.map {
            RenderDashboardPlan(id: $0.key, completed: response.plans?[$0.key], total: $0.value, team: declared?.planTeams[$0.key])
        }
        let pageOrigin = declared.map { "\($0.sourceURL) · TOTAL/PLANS · sha256 \($0.sha256)" }
        let rawOrigin = response.rawTotal != nil ? "api/status · rawTotal" : (response.total != nil ? "api/status · total" : pageOrigin)
        let postOrigin = response.postTotal != nil ? "api/status · postTotal" : (response.total != nil ? "api/status · total" : pageOrigin)
        let origins = [rawOrigin.map { "brut: " + $0 }, postOrigin.map { "post: " + $0 }].compactMap { $0 }
        let provenance: String? = origins.isEmpty ? nil : origins.joined(separator: "; ")
        return RenderDashboardJob(id: "shadow:" + (response.projectID ?? declared?.taskPrefix ?? "unidentified"),
            title: response.title ?? declared?.title ?? "Shadow · moniteur", projectID: response.projectID.map { "project:" + $0 } ?? declared.map { "declared-shadow:" + $0.taskPrefix } ?? "source:shadow",
            source: .shadowMonitor, workType: response.workType, rawCount: response.brut, postCount: response.post,
            rawProgress: raw, postProgress: post, totalProvenance: provenance, activity: activity, isFresh: fresh,
            observedAt: health.observedAt, lastActivity: timing.lastActivity, historicalMedianSeconds: timing.medianSeconds,
            sampledOutputsLastHour: timing.sampledOutputsLastHour, eta: fresh && activity == .running ? projection : nil,
            historicalETA: fresh && activity == .running ? nil : (RenderDate.parseOptional(response.eta) ?? projection),
            process: nil, gpu: RenderGPUMetrics(response.gpu), gpuRaw: response.gpu, plans: plans,
            tasks: response.tasks ?? [], stageDescription: "Provider Shadow non attribué au run · compteurs déclarés, aperçus non vérifiés", previewEntries: [])
    }

    static func applyingProjectLink(_ original: RenderDashboardJob, links: [String: String]) -> RenderDashboardJob {
        guard let label = links[original.id], !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return original }
        var linked = original
        linked.projectID = "label:" + label
        linked.projectTitle = label
        return linked
    }

    static func macHistory(jobID: String, root: String?, folders: [RenderEntry], monitors: [RenderEntry]) -> [RenderEntry] {
        let scoped = folders.filter { entry in
            guard let root, let path = entry.path else { return false }
            return RenderOrganization.isInside(path, root: root)
        }
        return RenderMerger.merge(folders: scoped, monitors: monitors.filter { $0.monitorJobID == jobID })
    }

    static func shadowHistory(roots: [String], folders: [RenderEntry], monitors: [RenderEntry]) -> [RenderEntry] {
        let scoped = folders.filter { entry in entry.path.map { path in roots.contains { RenderOrganization.isInside(path, root: $0) } } ?? false }
        return (scoped.isEmpty ? monitors : scoped).sorted { $0.modified > $1.modified }
    }

    static func folder(_ summary: RenderProjectSummary, health: SourceHealth) -> RenderDashboardJob {
        let source = summary.entries.first { $0.source == .macFolder || $0.source == .shadowFolder }?.source ?? .macFolder
        return RenderDashboardJob(id: "folders:" + summary.id, title: "Dossiers suivis", projectID: summary.id,
            source: source, workType: summary.workType, rawCount: nil, postCount: nil, rawProgress: nil, postProgress: nil,
            totalProvenance: nil, activity: .unknown, isFresh: health.online && !health.isStale, observedAt: health.observedAt,
            lastActivity: summary.latest?.modified, historicalMedianSeconds: nil, sampledOutputsLastHour: nil,
            eta: nil, historicalETA: nil, process: nil, gpu: nil, gpuRaw: nil, plans: [], tasks: [],
            stageDescription: "Dossiers suivis · aucune mesure de job", previewEntries: Array(summary.entries.filter { $0.fileMediaType == .image }.prefix(2)),
            projectTitle: summary.title)
    }

    static func projects(_ jobs: [RenderDashboardJob]) -> [RenderDashboardProject] {
        Dictionary(grouping: jobs, by: \.projectID).map { identity, versions in
            let title = versions.first.map { $0.projectTitle ?? ($0.source.isShadow ? $0.title : RenderOrganization.projectTitle($0.title)) } ?? "Projet non identifié"
            return RenderDashboardProject(id: identity, title: title, jobs: versions.sorted { $0.id < $1.id })
        }.sorted { $0.id < $1.id }
    }

    private static func estimatedDate(progress: RenderProgress?, timing: RenderTiming, observedAt: Date?, activity: RenderActivity) -> Date? {
        guard activity == .running, let progress, progress.completed < progress.total,
              let at = observedAt, let last = timing.lastActivity, let median = timing.medianSeconds,
              at.timeIntervalSince(last) <= max(4 * median, 900), median.isFinite else { return nil }
        let seconds = Double(progress.total - progress.completed) * median
        guard seconds.isFinite else { return nil }
        return at.addingTimeInterval(seconds)
    }
}


extension RenderDashboard {
    static func configuredShadowID(_ response: ShadowResponse, config: AppConfig) -> String? {
        guard let tasks=response.tasks, !tasks.isEmpty else { return nil }
        let matches=config.dashboardProjectLinks.keys.filter { key in
            guard key.hasPrefix("shadow:") else { return false }
            let prefix=String(key.dropFirst(7))
            return !prefix.isEmpty && tasks.allSatisfy { $0.name.hasPrefix(prefix) }
        }
        return matches.count == 1 ? matches.first : nil
    }
}


