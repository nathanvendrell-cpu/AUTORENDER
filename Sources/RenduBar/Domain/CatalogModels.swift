import Foundation
import CryptoKit

struct RenderProjectSummary: Identifiable {
    let title: String
    let entries: [RenderEntry]
    let workType: RenderWorkType?
    let id: String
    var latest: RenderEntry? { entries.max { $0.modified < $1.modified } }
    var countsByKind: [RenderKind: Int] { Dictionary(grouping: entries, by: \.kind).mapValues(\.count) }
    var countsBySource: [RenderSource: Int] { Dictionary(grouping: entries, by: \.source).mapValues(\.count) }
}

struct RenderCatalogWork: Identifiable, Codable {
    let id: String
    let projectID: String
    let title: String
    let workType: RenderWorkType?
    let jobs: [RenderDashboardJob]
}

struct RenderCatalogStateCounts: Codable {
    var archived = 0
    var running = 0
    var resumable = 0
    var stopped = 0
    var counted = 0
    var unknown = 0
    var historical = 0
}

struct RenderCatalogSnapshot {
    var archivedJobCount: Int { jobs.filter(\.isArchived).count }
    let revision: UInt64
    let generatedAt: Date
    let jobs: [RenderDashboardJob]
    let projects: [RenderDashboardProject]
    let works: [RenderCatalogWork]
    let knownJobCount: Int
    let observedJobCount: Int
    let stateCounts: RenderCatalogStateCounts
    let persistenceIssue: String?
    var reactivatedArchiveIDs: [String] = []
    var historyRevision:UInt64=0
    var libraryJobs:[RenderDashboardJob]=[]
    static let empty = RenderCatalogSnapshot(revision: 0, generatedAt: .distantPast, jobs: [], projects: [], works: [],
        knownJobCount: 0, observedJobCount: 0, stateCounts: RenderCatalogStateCounts(), persistenceIssue: nil)
}

struct RenderHistoryPage {
    let entries: [RenderEntry]
    let nextCursor: String?
    let totalKnown: Int?
    let coverage: String
    let snapshotRevision: UInt64
    var previousCursor: String? = nil
    var pageCursor: String? = nil
    var persistenceError: String? = nil
}


struct RenderFolderTarget: Identifiable, Codable {
    let id: String
    let title: String
    let location: URL?
    let remoteDisplay: String?
    let isVerified: Bool
    let verifiedAt: Date?
}

