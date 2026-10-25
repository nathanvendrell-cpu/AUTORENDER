import Foundation

/// Small display record; conversion from the canonical job stays at the UI boundary.
struct CatalogHierarchyRecord: Sendable {
    var id: String
    var title: String
    var projectID: String
    var projectTitle: String?
    var versionLabel: String?
    var isDetectedActiveRender: Bool
    var isFinishedRender: Bool
    var observedAt: Date?
    var lastActivity: Date?
}

/// Declared business context only. Missing levels remain explicit; labels never identify a client.
struct CatalogHierarchyContext: Sendable {
    var subprojectID: String? = nil
    var subprojectTitle: String? = nil
    var sceneID: String? = nil
    var sceneTitle: String? = nil
}

struct CatalogHierarchyRow: Identifiable {
    enum Kind { case subproject, scene, version, page }
    let id: String
    let parentID: String
    let kind: Kind
    let depth: Int
    let title: String
    let jobID: String?
    let count: Int
    let activeCount: Int
    let expanded: Bool
    let pageStart: Int
    let pageEnd: Int
    let previousPage: Bool
    let nextPage: Bool
}

/// Builds an index of data, never one SwiftUI card per historical version.
struct CatalogHierarchyNavigation: Sendable {
    var expanded: Set<String>
    var offsets: [String: Int]
}

// Built with exclusive worker ownership, then transferred to the main actor for navigation.
final class CatalogHierarchyIndex: @unchecked Sendable {
    private final class Node {
        let id: String
        let parent: String?
        let kind: CatalogHierarchyRow.Kind
        let title: String
        let sortTitle: String
        let jobID: String?
        var children: Set<String> = []
        var ordered: [String] = []
        var count = 0
        var active = 0
        var newest = Date.distantPast
        init(id: String, parent: String?, kind: CatalogHierarchyRow.Kind, title: String, jobID: String? = nil) {
            self.id = id; self.parent = parent; self.kind = kind; self.title = title; self.jobID = jobID
            sortTitle = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
        }
    }
    let pageSize: Int
    let maximumRows: Int
    private var nodes: [String: Node] = [:]
    private var roots: [String: String] = [:]
    private var versionNodes: [String: String] = [:]
    private var positions: [String: Int] = [:]
    private var offsets: [String: Int] = [:]
    private var expanded: Set<String> = []
    private(set) var jobsByID: [String: CatalogHierarchyRecord] = [:]
    private(set) var indexedJobs = 0
    private(set) var lastProjectionWasLimited = false
    init(pageSize: Int = 50, maximumRows: Int = 200) {
        self.pageSize = max(1, min(pageSize, 100))
        self.maximumRows = max(10, min(maximumRows, 500))
    }
    private static func component(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "u:" }
        return "v\(value.utf8.count):" + value
    }
    private static func label(_ value: String?, fallback: String) -> String {
        let value = (value ?? "").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return value.isEmpty ? fallback : value
    }
    @discardableResult func rebuild(_ jobs: [CatalogHierarchyRecord], cancelled: () -> Bool = { false },
                                    context: (CatalogHierarchyRecord) -> CatalogHierarchyContext) -> Bool {
        nodes = [:]; roots = [:]; versionNodes = [:]; positions = [:]; jobsByID = [:]
        for job in jobs {
            if cancelled() { return false }
            guard jobsByID[job.id] == nil else { continue }
            jobsByID[job.id] = job
            let context = context(job)
            let project = "p:" + Self.component(job.projectID)
            let subproject = project + "/s:" + Self.component(context.subprojectID)
            let scene = subproject + "/c:" + Self.component(context.sceneID)
            let version = scene + "/v:" + Self.component(job.id)
            roots[job.projectID] = project; versionNodes[job.id] = version
            let definitions: [(String, String?, CatalogHierarchyRow.Kind, String, String?)] = [
                (project, nil, .subproject, Self.label(job.projectTitle, fallback: "Projet non renseigné"), nil),
                (subproject, project, .subproject, Self.label(context.subprojectID == nil ? nil : context.subprojectTitle, fallback: "Sous-projet non renseigné"), nil),
                (scene, subproject, .scene, Self.label(context.sceneID == nil ? nil : context.sceneTitle, fallback: "Scène non renseignée"), nil),
                (version, scene, .version, Self.label(job.versionLabel ?? job.title, fallback: "Version sans nom"), job.id)
            ]
            let date = job.lastActivity ?? job.observedAt ?? .distantPast
            for (id, parent, kind, title, jobID) in definitions {
                let node = nodes[id] ?? Node(id: id, parent: parent, kind: kind, title: title, jobID: jobID)
                node.count += 1; node.active += job.isDetectedActiveRender ? 1 : 0
                node.newest = max(node.newest, date); nodes[id] = node
                if let parent { nodes[parent]?.children.insert(id) }
            }
        }
        indexedJobs = jobsByID.count
        for node in nodes.values {
            if cancelled() { return false }
            node.ordered = node.children.sorted { lhs, rhs in
                guard let a = nodes[lhs], let b = nodes[rhs] else { return lhs < rhs }
                if (a.active > 0) != (b.active > 0) { return a.active > 0 }
                if a.newest != b.newest { return a.newest > b.newest }
                if a.sortTitle != b.sortTitle { return a.sortTitle < b.sortTitle }
                return lhs < rhs
            }
            for (index, id) in node.ordered.enumerated() { positions[id] = index }
        }
        expanded = expanded.filter { nodes[$0] != nil }
        offsets = offsets.filter { nodes[$0.key] != nil }
        for key in Array(offsets.keys) {
            let last = max(0, ((nodes[key]?.ordered.count ?? 1) - 1) / pageSize * pageSize)
            offsets[key] = min(offsets[key] ?? 0, last)
        }
        return !cancelled()
    }
    var navigation: CatalogHierarchyNavigation { .init(expanded: expanded, offsets: offsets) }
    func restore(_ state: CatalogHierarchyNavigation) {
        expanded = state.expanded.filter { nodes[$0] != nil }
        offsets = state.offsets.filter { nodes[$0.key] != nil }
        for key in Array(offsets.keys) {
            let last = max(0, ((nodes[key]?.ordered.count ?? 1) - 1) / pageSize * pageSize)
            offsets[key] = min(offsets[key] ?? 0, last)
        }
    }
    func toggle(_ id: String) {
        guard let node = nodes[id], node.jobID == nil else { return }
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }
    func turnPage(_ parentID: String, forward: Bool) {
        guard let node = nodes[parentID] else { return }
        let last = max(0, (node.ordered.count - 1) / pageSize * pageSize)
        offsets[parentID] = min(last, max(0, (offsets[parentID] ?? 0) + (forward ? pageSize : -pageSize)))
    }
    /// Reveals the exact identity, including a version on a later page; no title matching.
    @discardableResult func reveal(jobID: String) -> Bool {
        guard var child = versionNodes[jobID] else { return false }
        while let parent = nodes[child]?.parent {
            expanded.insert(parent)
            offsets[parent] = ((positions[child] ?? 0) / pageSize) * pageSize
            child = parent
        }
        return true
    }
    func rows(projectID: String) -> [CatalogHierarchyRow] {
        lastProjectionWasLimited = false
        guard let root = roots[projectID] else { return [] }
        var rows: [CatalogHierarchyRow] = []
        func children(_ parentID: String, depth: Int) {
            guard let parent = nodes[parentID] else { return }
            let offset = offsets[parentID] ?? 0
            for id in parent.ordered.dropFirst(offset).prefix(pageSize) {
                guard rows.count < maximumRows, let node = nodes[id] else { lastProjectionWasLimited = true; return }
                rows.append(CatalogHierarchyRow(id: id, parentID: parentID, kind: node.kind, depth: depth,
                    title: node.title, jobID: node.jobID, count: node.count, activeCount: node.active,
                    expanded: expanded.contains(id), pageStart: 0, pageEnd: 0, previousPage: false, nextPage: false))
                if expanded.contains(id), node.jobID == nil { children(id, depth: depth + 1) }
            }
            if parent.ordered.count > pageSize {
                guard rows.count < maximumRows else { lastProjectionWasLimited = true; return }
                rows.append(CatalogHierarchyRow(id: "page:" + parentID, parentID: parentID, kind: .page, depth: depth,
                    title: "", jobID: nil, count: parent.ordered.count, activeCount: parent.active, expanded: true,
                    pageStart: offset + 1, pageEnd: min(offset + pageSize, parent.ordered.count),
                    previousPage: offset > 0, nextPage: offset + pageSize < parent.ordered.count))
            }
        }
        children(root, depth: 0)
        return rows
    }
}
