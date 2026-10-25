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

struct RenderLocalPreviewProof:Codable,Equatable {
    let jobID:String
    let sha256:String
    let stamp:RenderLibraryFileStamp
    let changedSeconds:Int64
    let changedNanoseconds:Int64
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
    var localPreviewProof:RenderLocalPreviewProof?=nil

    var fileMediaType: RenderKind { RenderKind.classify(filename) }
    var kind: RenderKind { RenderKind.classify(filename) }
    var isVideo: Bool { kind == .video }
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

