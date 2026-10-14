import Foundation
import CryptoKit

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
    var jobArchives: [String:Date] = [:]
    var nativeMetadataSources:[String:NativeMetadataSourceConfig] = [:]
    var shadowRunSources:[ShadowDeclaredSource] = []
    var archivePayloadError: String? = nil

    private enum CodingKeys: String, CodingKey { case macFolders, shadowFolders, dismissedMacFolders, folderProjects, folderWorkTypes, dashboardProjectLinks, dashboardJobFolders, jobContexts, remoteMirrors, jobArchives, nativeMetadataSources, shadowRunSources }

    init(macFolders: [String] = [], shadowFolders: [String] = [], dismissedMacFolders: [String] = [],
         folderProjects: [String: String] = [:], folderWorkTypes: [String: RenderWorkType] = [:], dashboardProjectLinks: [String: String] = [:], dashboardJobFolders: [String: [String]] = [:], jobContexts: [String: RenderJobContext] = [:], remoteMirrors: [String:String] = [:], jobArchives: [String:Date] = [:]) {
        self.macFolders = macFolders
        self.shadowFolders = shadowFolders
        self.dismissedMacFolders = dismissedMacFolders
        self.folderProjects = folderProjects
        self.folderWorkTypes = folderWorkTypes
        self.dashboardProjectLinks = dashboardProjectLinks
        self.dashboardJobFolders = dashboardJobFolders
        self.jobContexts = jobContexts
        self.remoteMirrors = remoteMirrors
        self.jobArchives = jobArchives
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        shadowRunSources = try values.decodeIfPresent([ShadowDeclaredSource].self,forKey:.shadowRunSources) ?? []
        macFolders = try values.decodeIfPresent([String].self, forKey: .macFolders) ?? []
        shadowFolders = try values.decodeIfPresent([String].self, forKey: .shadowFolders) ?? []
        dismissedMacFolders = try values.decodeIfPresent([String].self, forKey: .dismissedMacFolders) ?? []
        folderProjects = try values.decodeIfPresent([String: String].self, forKey: .folderProjects) ?? [:]
        folderWorkTypes = (try values.decodeIfPresent([String: String].self, forKey: .folderWorkTypes) ?? [:]).compactMapValues(RenderWorkType.init(rawValue:))
        dashboardProjectLinks = try values.decodeIfPresent([String: String].self, forKey: .dashboardProjectLinks) ?? [:]
        dashboardJobFolders = try values.decodeIfPresent([String: [String]].self, forKey: .dashboardJobFolders) ?? [:]
        jobContexts = try values.decodeIfPresent([String: RenderJobContext].self, forKey: .jobContexts) ?? [:]
        nativeMetadataSources = try values.decodeIfPresent([String:NativeMetadataSourceConfig].self,forKey:.nativeMetadataSources) ?? [:]
        remoteMirrors = try values.decodeIfPresent([String:String].self, forKey: .remoteMirrors) ?? [:]
        do {
            jobArchives = try values.decodeIfPresent([String:Date].self,forKey:.jobArchives) ?? [:]
            if jobArchives.keys.contains(where:{ !$0.hasPrefix("mac:") && !$0.hasPrefix("shadow:") && !$0.hasPrefix("folders:") }) {
                jobArchives=[:];archivePayloadError="Préférences d’archive futures · données préservées"
            }
        }
        catch { jobArchives=[:]; archivePayloadError="Préférences d’archive illisibles ou futures · données préservées" }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(shadowRunSources,forKey:.shadowRunSources)
        try values.encode(macFolders, forKey: .macFolders)
        try values.encode(shadowFolders, forKey: .shadowFolders)
        try values.encode(dismissedMacFolders, forKey: .dismissedMacFolders)
        try values.encode(folderProjects, forKey: .folderProjects)
        try values.encode(folderWorkTypes, forKey: .folderWorkTypes)
        try values.encode(dashboardProjectLinks, forKey: .dashboardProjectLinks)
        try values.encode(dashboardJobFolders, forKey: .dashboardJobFolders)
        try values.encode(jobContexts, forKey: .jobContexts)
        try values.encode(remoteMirrors, forKey: .remoteMirrors)
        try values.encode(jobArchives, forKey: .jobArchives)
        try values.encode(nativeMetadataSources,forKey:.nativeMetadataSources)
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

struct RenderJobContext: Codable, Equatable {
    var projectID: String?
    var workID: String?
    var versionID: String?
    var workTitle: String?
    var versionLabel: String?
}

