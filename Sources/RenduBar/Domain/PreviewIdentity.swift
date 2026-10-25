import Foundation
import CryptoKit

enum RenderPreviewRequest {
    static func cacheIdentity(_ entry:RenderEntry) -> String {
        var values=[entry.id,entry.source.rawValue,entry.path ?? "",entry.previewURL ?? "",String(entry.modified.timeIntervalSinceReferenceDate)]
        let proofEncoder=JSONEncoder();proofEncoder.outputFormatting=[.sortedKeys]
        if let proof=entry.localPreviewProof,let encoded=try? proofEncoder.encode(proof) {values.append(SHA256.hash(data:encoded).map{String(format:"%02x",$0)}.joined())}
        let data=(try? JSONEncoder().encode(values)) ?? Data()
        return SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
    }
    static func fingerprint(entries:[RenderEntry]) -> String {
        let values=entries.map { cacheIdentity($0) + ":" + $0.state.rawValue }.sorted()
        return SHA256.hash(data:Data(values.joined(separator:"|").utf8)).map { String(format:"%02x",$0) }.joined()
    }
}
