import Foundation
import CryptoKit

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

