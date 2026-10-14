import Foundation
enum Filter: String, CaseIterable { case all = "Ensemble", mac = "Mac", shadow = "Shadow" }
enum WorkFilter: String, CaseIterable {
    case all = "Tous les travaux", video = "Vidéo", image = "Image / photo", audio = "Audio / musique", other = "Autres", unknown = "Non identifié"
    func matches(_ type: RenderWorkType?) -> Bool {
        switch self {
        case .all: return true
        case .video: return type == .video
        case .image: return type == .image
        case .audio: return type == .audio
        case .other: return type == .other
        case .unknown: return type == nil
        }
    }
}

// UI projection is rebuilt only for a snapshot/filter change; it never parses source payloads.
enum CatalogScope: String, CaseIterable {
    case follow = "À suivre", direct = "En cours", finished = "Terminés", archived = "Archives", all = "Tous"
    static let mainSections: [CatalogScope] = [.direct, .finished, .archived]
    static func dashboardScope(for job: RenderDashboardJob) -> CatalogScope? {
        if CatalogScope.direct.matches(job) { return .direct }
        if job.isArchived && job.isTerminalCounted { return .archived }
        if job.isFinishedRender { return .finished }
        return nil
    }
    func matches(_ job: RenderDashboardJob) -> Bool {
        let active = job.isDetectedActiveRender
        switch self {
        case .follow: return !job.isArchived || active
        case .direct: return active
        case .finished: return job.isFinishedRender
        case .archived: return job.isArchived && job.isTerminalCounted
        case .all: return true
        }
    }
}

struct CatalogSection: Identifiable {
    let id: String
    let title: String
    let jobs: [RenderDashboardJob]
}

