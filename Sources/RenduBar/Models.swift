import Foundation
import CryptoKit

enum RenderSource: String, Codable {
    case shadowMonitor = "Shadow"
    case macMonitor = "Mac · moniteur"
    case macFolder = "Mac · dossier"
    case shadowFolder = "Shadow · dossier"

    var isShadow: Bool { self == .shadowMonitor || self == .shadowFolder }
}

enum RenderState: String, Codable {
    case complete = "Lisible"
    case stable = "Stable"
    case pending = "À vérifier"
}

enum RenderKind: String, CaseIterable {
    case video = "Vidéo"
    case image = "Image / photo"
    case audio = "Audio / musique"
    case other = "Autres rendus"

    static func classify(_ filename: String) -> RenderKind {
        let ext = (filename as NSString).pathExtension.lowercased()
        if ["mov", "mp4", "m4v", "avi"].contains(ext) { return .video }
        if ["png", "jpg", "jpeg", "tif", "tiff", "exr"].contains(ext) { return .image }
        if ["wav", "aif", "aiff", "flac", "mp3", "m4a", "aac", "ogg"].contains(ext) { return .audio }
        return .other
    }

    static func isSupportedExport(_ filename: String) -> Bool {
        let ext = (filename as NSString).pathExtension.lowercased()
        return classify(filename) != .other || ["pdf", "glb", "gltf", "usdz"].contains(ext)
    }
}

// Work category is declared by a job or user, never inferred from output extensions.
enum RenderWorkType: String, Codable, CaseIterable {
    case video = "video"
    case image = "image"
    case audio = "audio"
    case other = "other"

    var label: String {
        switch self {
        case .video: return "Vidéo"
        case .image: return "Image / photo"
        case .audio: return "Audio / musique"
        case .other: return "Autres"
        }
    }
}

struct RenderEntry: Identifiable, Codable, Equatable {
    let id: String
    let source: RenderSource
    let job: String
    let filename: String
    let modified: Date
    var state: RenderState
    let path: String?
    let previewURL: String?
    var monitorJobID: String? = nil

    var fileMediaType: RenderKind { RenderKind.classify(filename) }
    var kind: RenderKind { RenderKind.classify(filename) }
    var isVideo: Bool { kind == .video }
}

enum RenderMerger {
    static func merge(folders: [RenderEntry], monitors: [RenderEntry]) -> [RenderEntry] {
        var selected = folders
        var consumed = Set<Int>()
        for (apiIndex, api) in monitors.enumerated() {
            let matchingFolders = folders.indices.filter { sameMacFile(folders[$0], api) }
            guard matchingFolders.count == 1 else { continue }
            let folderIndex = matchingFolders[0]
            // If several monitor jobs could name this file, preserve every entry.
            guard monitors.filter({ sameMacFile(folders[folderIndex], $0) }).count == 1 else { continue }
            consumed.insert(apiIndex)
            if api.state == .complete && selected[folderIndex].state != .complete {
                selected[folderIndex] = api
            }
        }
        for (index, api) in monitors.enumerated() where !consumed.contains(index) { selected.append(api) }
        return selected.sorted { $0.modified > $1.modified }
    }

    private static func sameMacFile(_ folder: RenderEntry, _ api: RenderEntry) -> Bool {
        guard folder.source == .macFolder, api.source == .macMonitor,
              let folderPath = folder.path, let apiPath = api.path else { return false }
        return URL(fileURLWithPath: folderPath).standardizedFileURL.path
            == URL(fileURLWithPath: apiPath).standardizedFileURL.path
            && abs(folder.modified.timeIntervalSince(api.modified)) <= 2
    }
}

enum ShadowListing {
    // The API has no file identity shared with SSH. Use one listing, never an unsafe name-based merge.
    static func entries(monitor: [RenderEntry], folders: [RenderEntry],
                        remoteOnline: Bool, foldersConfigured: Bool) -> [RenderEntry] {
        foldersConfigured && (remoteOnline || monitor.isEmpty) ? folders : monitor
    }
}

struct SourceHealth: Codable {
    var online = false
    var partial = false
    var isStale = false
    var observedAt: Date?

    var freshnessLabel: String {
        if isStale { return "Données périmées" }
        return online ? "Relevé récent" : "Dernier relevé"
    }
    var checkedAt: Date?
    var lastGoodAt: Date?
    var message = "En attente"

    var label: String {
        if online { return isStale ? "Données périmées" : (partial ? "Partiel" : "En direct") }
        guard let lastGoodAt else { return "Hors ligne" }
        return "Hors ligne · dernier relevé " + lastGoodAt.formatted(date: .abbreviated, time: .shortened)
    }
}

struct AppConfig: Codable {
    var macFolders: [String] = []
    var shadowFolders: [String] = []
    var dismissedMacFolders: [String] = []
    var folderProjects: [String: String] = [:]
    var folderWorkTypes: [String: RenderWorkType] = [:]
    var dashboardProjectLinks: [String: String] = [:]
    var dashboardJobFolders: [String: [String]] = [:]
    var jobContexts: [String: RenderJobContext] = [:]
    var remoteMirrors: [String: String] = [:]

    private enum CodingKeys: String, CodingKey { case macFolders, shadowFolders, dismissedMacFolders, folderProjects, folderWorkTypes, dashboardProjectLinks, dashboardJobFolders, jobContexts, remoteMirrors }

    init(macFolders: [String] = [], shadowFolders: [String] = [], dismissedMacFolders: [String] = [],
         folderProjects: [String: String] = [:], folderWorkTypes: [String: RenderWorkType] = [:], dashboardProjectLinks: [String: String] = [:], dashboardJobFolders: [String: [String]] = [:], jobContexts: [String: RenderJobContext] = [:], remoteMirrors: [String:String] = [:]) {
        self.macFolders = macFolders
        self.shadowFolders = shadowFolders
        self.dismissedMacFolders = dismissedMacFolders
        self.folderProjects = folderProjects
        self.folderWorkTypes = folderWorkTypes
        self.dashboardProjectLinks = dashboardProjectLinks
        self.dashboardJobFolders = dashboardJobFolders
        self.jobContexts = jobContexts
        self.remoteMirrors = remoteMirrors
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        macFolders = try values.decodeIfPresent([String].self, forKey: .macFolders) ?? []
        shadowFolders = try values.decodeIfPresent([String].self, forKey: .shadowFolders) ?? []
        dismissedMacFolders = try values.decodeIfPresent([String].self, forKey: .dismissedMacFolders) ?? []
        folderProjects = try values.decodeIfPresent([String: String].self, forKey: .folderProjects) ?? [:]
        folderWorkTypes = (try values.decodeIfPresent([String: String].self, forKey: .folderWorkTypes) ?? [:]).compactMapValues(RenderWorkType.init(rawValue:))
        dashboardProjectLinks = try values.decodeIfPresent([String: String].self, forKey: .dashboardProjectLinks) ?? [:]
        dashboardJobFolders = try values.decodeIfPresent([String: [String]].self, forKey: .dashboardJobFolders) ?? [:]
        jobContexts = try values.decodeIfPresent([String: RenderJobContext].self, forKey: .jobContexts) ?? [:]
        remoteMirrors = try values.decodeIfPresent([String:String].self, forKey: .remoteMirrors) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(macFolders, forKey: .macFolders)
        try values.encode(shadowFolders, forKey: .shadowFolders)
        try values.encode(dismissedMacFolders, forKey: .dismissedMacFolders)
        try values.encode(folderProjects, forKey: .folderProjects)
        try values.encode(folderWorkTypes, forKey: .folderWorkTypes)
        try values.encode(dashboardProjectLinks, forKey: .dashboardProjectLinks)
        try values.encode(dashboardJobFolders, forKey: .dashboardJobFolders)
        try values.encode(jobContexts, forKey: .jobContexts)
        try values.encode(remoteMirrors, forKey: .remoteMirrors)
    }

    static func normalizedMacFolder(_ raw: String) -> String {
        URL(fileURLWithPath: raw, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL.path
    }

    mutating func importNewMacMonitorFolders(_ candidates: [String]) -> [String] {
        let existing = Set(macFolders.map(Self.normalizedMacFolder))
        let dismissed = Set(dismissedMacFolders.map(Self.normalizedMacFolder))
        var seen = existing
        var added: [String] = []
        for raw in candidates {
            let folder = Self.normalizedMacFolder(raw)
            var isDirectory: ObjCBool = false
            guard !seen.contains(folder), !dismissed.contains(folder),
                  FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            seen.insert(folder)
            macFolders.append(folder)
            added.append(folder)
        }
        return added
    }

    mutating func addMacFolder(_ raw: String) {
        let folder = Self.normalizedMacFolder(raw)
        dismissedMacFolders.removeAll { Self.normalizedMacFolder($0) == folder }
        if !macFolders.map(Self.normalizedMacFolder).contains(folder) { macFolders.append(folder) }
    }

    mutating func removeMacFolder(_ raw: String) {
        let folder = Self.normalizedMacFolder(raw)
        macFolders.removeAll { Self.normalizedMacFolder($0) == folder }
        if !dismissedMacFolders.map(Self.normalizedMacFolder).contains(folder) { dismissedMacFolders.append(folder) }
    }

    private struct ExistingMacJob: Decodable {
        let id: String?
        let dossier: String
    }

    private static func existingMacJobs() -> [ExistingMacJob] {
        let source = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support/RenduBar/monitor-jobs.json")
        return (try? Data(contentsOf: source)).flatMap {
            try? JSONDecoder().decode([ExistingMacJob].self, from: $0)
        } ?? []
    }

    static func knownMacMonitorFolders() -> [String: String] {
        var folders: [String: String] = [:]
        var ambiguous = Set<String>()
        for job in existingMacJobs() {
            guard let id = job.id, !id.isEmpty else { continue }
            if folders[id] != nil { ambiguous.insert(id) }
            var directory: ObjCBool = false
            if FileManager.default.fileExists(atPath: job.dossier, isDirectory: &directory), directory.boolValue {
                folders[id] = job.dossier
            }
        }
        for id in ambiguous { folders.removeValue(forKey: id) }
        return folders
    }

    static func bootstrap() -> AppConfig {
        let mac = Array(Set(knownMacMonitorFolders().values.map(normalizedMacFolder))).sorted()
        return AppConfig(macFolders: mac)
    }
}

enum RenderOrganization {
    static func projectTitle(_ title: String) -> String {
        let prefix = title.components(separatedBy: " — ").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return prefix.isEmpty ? "Projet non identifié" : prefix
    }

    static func project(for entry: RenderEntry, jobs: [MacJob], knownFolders: [String: String],
                        labels: [String: String]) -> String {
        if let path = entry.path,
           let label = labels.sorted(by: { $0.key.count > $1.key.count }).first(where: { root, label in
               !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                   && isInside(path, root: root)
           })?.value {
            return label
        }
        if entry.source == .macMonitor { return projectTitle(entry.job) }
        if entry.source == .macFolder, let path = entry.path {
            for job in jobs {
                if let root = knownFolders[job.id], isInside(path, root: root) {
                    return projectTitle(job.titre)
                }
            }
            if let sourceName = datedProjectSegment(path) { return sourceName }
            let folder = URL(fileURLWithPath: path).deletingLastPathComponent()
            return "Dossier Mac · " + folder.lastPathComponent
        }
        if let path = entry.path, let sourceName = datedProjectSegment(path) { return sourceName }
        return entry.source.isShadow ? "Shadow · projet non identifié" : "Projet non identifié"
    }

    static func projectID(for entry: RenderEntry, jobs: [MacJob], knownFolders: [String: String],
                          labels: [String: String]) -> String {
        if let path = entry.path,
           let label = labels.sorted(by: { $0.key.count > $1.key.count }).first(where: {
               !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && isInside(path, root: $0.key)
           })?.value { return "label:" + label }
        if let id = entry.monitorJobID {
            let job = jobs.first { $0.id == id }
            return job?.projectID.map { "project:" + $0 } ?? "job:" + id
        }
        if let path = entry.path {
            let mapped = jobs.sorted { (knownFolders[$0.id]?.count ?? 0) > (knownFolders[$1.id]?.count ?? 0) }
                .first { knownFolders[$0.id].map { isInside(path, root: $0) } ?? false }
            if let job = mapped { return job.projectID.map { "project:" + $0 } ?? "job:" + job.id }
            let windows = entry.source.isShadow
            let normalized = path.replacingOccurrences(of: "\\", with: "/")
            if let dated = datedProjectSegment(normalized) {
                let prefix = normalized.components(separatedBy: dated).first ?? ""
                return "path:" + (windows ? (prefix + dated).lowercased() : prefix + dated)
            }
            let parent = windows ? normalized.split(separator: "/").dropLast().joined(separator: "/") : URL(fileURLWithPath: normalized).deletingLastPathComponent().standardizedFileURL.path
            return "folder:" + (windows ? parent.lowercased() : parent)
        }
        return "unidentified:" + entry.source.rawValue
    }

    static func workType(for entry: RenderEntry, jobs: [MacJob], knownFolders: [String: String],
                         configured: [String: RenderWorkType]) -> RenderWorkType? {
        if let path = entry.path,
           let choice = configured.sorted(by: { $0.key.count > $1.key.count }).first(where: { isInside(path, root: $0.key) }) {
            return choice.value
        }
        let matching = jobs.filter { job in
            if let path = entry.path, let root = knownFolders[job.id], isInside(path, root: root) { return true }
            return entry.source == .macMonitor && (entry.monitorJobID.map { $0 == job.id } ?? (entry.job == job.titre))
        }
        let types = Set(matching.compactMap(\.workType))
        return types.count == 1 ? types.first : nil
    }

    static func isConfirmedFinal(_ entry: RenderEntry, jobs: [MacJob],
                                 knownFolders: [String: String]) -> Bool {
        if entry.source == .macMonitor { return hasFinalMarker(entry.job) }
        guard let path = entry.path else { return false }
        if entry.source == .macFolder {
            for job in jobs {
                if let root = knownFolders[job.id], isInside(path, root: root),
                   hasFinalMarker(job.titre) { return true }
            }
        }
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        let folderName = URL(fileURLWithPath: normalized).deletingLastPathComponent().lastPathComponent
        return hasFinalMarker(folderName)
    }

    private static func hasFinalMarker(_ value: String) -> Bool {
        let lower = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        return lower.range(of: #"(^|[^a-z])fin(al|aux)([^a-z]|$)"#, options: .regularExpression) != nil
    }

    static func isInside(_ path: String, root: String) -> Bool {
        let windows = root.count > 1 && root.dropFirst().first == ":"
        let normalizedPath = windows ? path.replacingOccurrences(of: "\\", with: "/").lowercased() : URL(fileURLWithPath: path).standardizedFileURL.path
        var normalizedRoot = windows ? root.replacingOccurrences(of: "\\", with: "/").lowercased() : URL(fileURLWithPath: root).standardizedFileURL.path
        while normalizedRoot.hasSuffix("/") { normalizedRoot.removeLast() }
        return normalizedPath.hasPrefix(normalizedRoot + "/")
    }

    private static func datedProjectSegment(_ path: String) -> String? {
        path.replacingOccurrences(of: "\\", with: "/").split(separator: "/")
            .map(String.init)
            .first { $0.range(of: #"^.{3,}_20[0-9]{6}$"#, options: .regularExpression) != nil }
    }
}

struct ShadowFrame: Codable {
    let name: String
    let t: String?
}

struct ShadowTask: Codable {
    let name: String
    let state: String
}

struct ShadowResponse: Codable {
    let ok: Bool
    let now: String?
    let brut: Int?
    let post: Int?
    let latest: [ShadowFrame]?
    let tasks: [ShadowTask]?
    let blender: Int?
    let error: String?
    var total: Int? = nil
    var rawTotal: Int? = nil
    var postTotal: Int? = nil
    var times: [String]? = nil
    var plans: [String: Int]? = nil
    var gpu: String? = nil
    var fetched: String? = nil
    var projectID: String? = nil
    var title: String? = nil
    var workType: RenderWorkType? = nil
    var eta: String? = nil
    var workID: String? = nil
    var versionID: String? = nil
    private enum CodingKeys:String,CodingKey { case ok,now,brut,post,latest,tasks,blender,error,total,rawTotal,postTotal,times,plans,gpu,fetched,projectID,title,eta,workID,versionID,workType }
    init(from decoder:Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        ok = try c.decode(Bool.self,forKey:.ok)
        now = try c.decodeIfPresent(String.self,forKey:.now)
        brut = try c.decodeIfPresent(Int.self,forKey:.brut)
        post = try c.decodeIfPresent(Int.self,forKey:.post)
        latest = try c.decodeIfPresent([ShadowFrame].self,forKey:.latest)
        tasks = try c.decodeIfPresent([ShadowTask].self,forKey:.tasks)
        blender = try c.decodeIfPresent(Int.self,forKey:.blender)
        error = try c.decodeIfPresent(String.self,forKey:.error)
        total = try c.decodeIfPresent(Int.self,forKey:.total)
        rawTotal = try c.decodeIfPresent(Int.self,forKey:.rawTotal)
        postTotal = try c.decodeIfPresent(Int.self,forKey:.postTotal)
        times = try c.decodeIfPresent([String].self,forKey:.times)
        plans = try c.decodeIfPresent([String:Int].self,forKey:.plans)
        gpu = try c.decodeIfPresent(String.self,forKey:.gpu)
        fetched = try c.decodeIfPresent(String.self,forKey:.fetched)
        projectID = try c.decodeIfPresent(String.self,forKey:.projectID)
        title = try c.decodeIfPresent(String.self,forKey:.title)
        eta = try c.decodeIfPresent(String.self,forKey:.eta)
        workID = try c.decodeIfPresent(String.self,forKey:.workID)
        versionID = try c.decodeIfPresent(String.self,forKey:.versionID)
        workType = (try c.decodeIfPresent(String.self,forKey:.workType)).flatMap(RenderWorkType.init(rawValue:))
    }

}

struct MacProcess: Codable {
    let cpu: String?
    let ram_mo: Int?
    let duree: String?
}

struct MacJob: Codable {
    let id: String
    let titre: String
    let sous: String?
    let total: Int
    let faites: Int
    let en_cours: [String]
    let latest: [String]
    let times: [String]
    let proc: MacProcess?
    let workType: RenderWorkType?
    let projectID: String?
    var workID: String? = nil
    var versionID: String? = nil
    var processReported = true
    var eta: String? = nil

    var progress: RenderProgress? { RenderProgress(completed: faites, total: total) }

    private enum CodingKeys: String, CodingKey { case id, titre, sous, total, faites, en_cours, latest, times, proc, workType, projectID, eta, workID, versionID }

    init(id: String, titre: String, sous: String?, total: Int, faites: Int, en_cours: [String],
         latest: [String], times: [String], proc: MacProcess?, workType: RenderWorkType? = nil, projectID: String? = nil) {
        self.id = id; self.titre = titre; self.sous = sous; self.total = total; self.faites = faites
        self.en_cours = en_cours; self.latest = latest; self.times = times; self.proc = proc; self.workType = workType; self.projectID = projectID
    }

    init(from decoder: Decoder) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        id = try v.decode(String.self, forKey: .id)
        titre = try v.decode(String.self, forKey: .titre)
        sous = try v.decodeIfPresent(String.self, forKey: .sous)
        total = try v.decodeIfPresent(Int.self, forKey: .total) ?? 0
        faites = try v.decodeIfPresent(Int.self, forKey: .faites) ?? -1
        en_cours = try v.decodeIfPresent([String].self, forKey: .en_cours) ?? []
        latest = try v.decodeIfPresent([String].self, forKey: .latest) ?? []
        times = try v.decodeIfPresent([String].self, forKey: .times) ?? []
        proc = try v.decodeIfPresent(MacProcess.self, forKey: .proc)
        workID = try v.decodeIfPresent(String.self, forKey: .workID)
        versionID = try v.decodeIfPresent(String.self, forKey: .versionID)
        processReported = v.contains(.proc)
        eta = try v.decodeIfPresent(String.self, forKey: .eta)
        workType = (try v.decodeIfPresent(String.self, forKey: .workType)).flatMap(RenderWorkType.init(rawValue:))
        projectID = try v.decodeIfPresent(String.self, forKey: .projectID)
    }
}

struct RenderProgress: Equatable, Codable {
    let completed: Int
    let total: Int
    init?(completed: Int, total: Int) {
        guard total > 0, completed >= 0, completed <= total else { return nil }
        self.completed = completed; self.total = total
    }
    var fraction: Double { Double(completed) / Double(total) }
    var countLabel: String { "\(completed)/\(total)" }
    var percentLabel: String { String(format: "%.1f %%", fraction * 100) }
}

struct RenderProjectSummary: Identifiable {
    let title: String
    let entries: [RenderEntry]
    let workType: RenderWorkType?
    let id: String
    var latest: RenderEntry? { entries.max { $0.modified < $1.modified } }
    var countsByKind: [RenderKind: Int] { Dictionary(grouping: entries, by: \.kind).mapValues(\.count) }
    var countsBySource: [RenderSource: Int] { Dictionary(grouping: entries, by: \.source).mapValues(\.count) }
}

struct MacResponse: Codable {
    let ok: Bool
    let now: String?
    let jobs: [MacJob]
}

enum RenderDate {
    private static let lock = NSLock()
    private static var cache: [String: Date] = [:]
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let iso = ISO8601DateFormatter()
    private static let local: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"; return f
    }()
    static func parseOptional(_ text: String?) -> Date? {
        guard let text else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let date = cache[text] { return date }
        let result = fractional.date(from: text) ?? iso.date(from: text) ?? local.date(from: text)
        if let result {
            if cache.count >= 8192 { cache.removeAll(keepingCapacity: true) }
            cache[text] = result
        }
        return result
    }
    static func parse(_ text: String?) -> Date { parseOptional(text) ?? .distantPast }
}

// Freshness describes a measurement, never process activity.
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
    var retainedHistorical = false
    var estimatedRemainingSeconds: Double? = nil

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

struct RenderTiming {
    let lastActivity: Date?
    let medianSeconds: Double?
    let sampledOutputsLastHour: Int?
    init(times: [String], at: Date?) {
        let dates = times.compactMap(RenderDate.parseOptional).filter { date in at.map { date <= $0 } ?? true }
        lastActivity = dates.max()
        let sorted = dates.sorted()
        let gaps = zip(sorted, sorted.dropFirst()).map { $1.timeIntervalSince($0) }.filter { $0 > 0 && $0.isFinite }.sorted()
        if gaps.isEmpty { medianSeconds = nil }
        else if gaps.count % 2 == 0 { medianSeconds = (gaps[gaps.count / 2 - 1] + gaps[gaps.count / 2]) / 2 }
        else { medianSeconds = gaps[gaps.count / 2] }
        sampledOutputsLastHour = at.map { reference in dates.filter { reference.timeIntervalSince($0) >= 0 && reference.timeIntervalSince($0) <= 3600 }.count }
    }
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
        let activity: RenderActivity
        if let processes = response.blender, processes > 0 { activity = .running }
        else if response.blender == 0 {
            if raw.map({ $0.completed < $0.total }) == true || post.map({ $0.completed < $0.total }) == true { activity = .resumeRequired }
            else if raw != nil && post != nil { activity = .countsReached }
            else { activity = .stopped }
        } else { activity = .unknown }
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
            tasks: response.tasks ?? [], stageDescription: nil, previewEntries: Array(previews.sorted { $0.modified > $1.modified }.prefix(2)))
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


struct RenderJobContext: Codable, Equatable {
    var projectID: String?
    var workID: String?
    var versionID: String?
    var workTitle: String?
    var versionLabel: String?
}

struct RenderCatalogWork: Identifiable, Codable {
    let id: String
    let projectID: String
    let title: String
    let workType: RenderWorkType?
    let jobs: [RenderDashboardJob]
}

struct RenderCatalogStateCounts: Codable {
    var running = 0
    var resumable = 0
    var stopped = 0
    var counted = 0
    var unknown = 0
    var historical = 0
}

struct RenderCatalogSnapshot {
    let revision: UInt64
    let generatedAt: Date
    let jobs: [RenderDashboardJob]
    let projects: [RenderDashboardProject]
    let works: [RenderCatalogWork]
    let knownJobCount: Int
    let observedJobCount: Int
    let stateCounts: RenderCatalogStateCounts
    let persistenceIssue: String?
    static let empty = RenderCatalogSnapshot(revision: 0, generatedAt: .distantPast, jobs: [], projects: [], works: [],
        knownJobCount: 0, observedJobCount: 0, stateCounts: RenderCatalogStateCounts(), persistenceIssue: nil)
}

struct RenderHistoryPage {
    let entries: [RenderEntry]
    let nextCursor: String?
    let totalKnown: Int?
    let coverage: String
    let snapshotRevision: UInt64
}


struct RenderFolderTarget: Identifiable, Codable {
    let id: String
    let title: String
    let location: URL?
    let remoteDisplay: String?
    let isVerified: Bool
    let verifiedAt: Date?
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
