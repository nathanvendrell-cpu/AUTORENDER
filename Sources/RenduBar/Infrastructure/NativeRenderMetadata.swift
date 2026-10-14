import Foundation

struct NativeRenderMetadata: Decodable {
    let schemaVersion: Int
    let source: String
    let runID: String
    let processIdentity: NativeProcessIdentity
    let outputRoot: String
    let observedAt: String
    let projectID: String?
    let workID: String?
    let versionID: String?
    let workType: String?
    let outputRole: String?
    // Invalid counters do not invalidate the identity, but cannot produce determinate progress.
    let completed: Int?
    let total: Int?
    private enum CodingKeys:String,CodingKey { case schemaVersion,source,runID,processIdentity,outputRoot,observedAt,projectID,workID,versionID,workType,outputRole,completed,total }
    init(from decoder: Decoder) throws {
        let values=try decoder.container(keyedBy:CodingKeys.self)
        schemaVersion=try values.decode(Int.self,forKey:.schemaVersion)
        source=try values.decode(String.self,forKey:.source)
        runID=try values.decode(String.self,forKey:.runID)
        processIdentity=try values.decode(NativeProcessIdentity.self,forKey:.processIdentity)
        outputRoot=try values.decode(String.self,forKey:.outputRoot)
        observedAt=try values.decode(String.self,forKey:.observedAt)
        projectID=try values.decodeIfPresent(String.self,forKey:.projectID)
        workID=try values.decodeIfPresent(String.self,forKey:.workID)
        versionID=try values.decodeIfPresent(String.self,forKey:.versionID)
        workType=try values.decodeIfPresent(String.self,forKey:.workType)
        outputRole=try values.decodeIfPresent(String.self,forKey:.outputRole)
        completed=try? values.decode(Int.self,forKey:.completed)
        total=try? values.decode(Int.self,forKey:.total)
    }
    static func read(_ url: URL, for observation: NativeRenderObservation, now: Date, permit:RenderIOPermit? = nil) -> (Self,Date)? {
        guard let attrs=try? url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.contentModificationDateKey]),
              attrs.isRegularFile==true,attrs.isSymbolicLink != true,let modified=attrs.contentModificationDate else { return nil }
        guard let data=try? RenderRegularFile.read(url,maximumBytes:32*1024,permit:permit,allowSymlink:false),
              let value=try? JSONDecoder().decode(Self.self,from:data),value.schemaVersion==1,
              value.source.lowercased()==observation.producer.lowercased(),value.processIdentity==observation.identity,
              validID(value.runID),[value.projectID,value.workID,value.versionID].compactMap({$0}).allSatisfy(validID),
              value.workType == nil || value.workType.flatMap(RenderWorkType.init(rawValue:)) != nil,
              value.outputRole == nil || ["direct","export","raw","post"].contains(value.outputRole!),
              let absolute=NativeRenderPaths.absolute(value.outputRoot),NativeRenderPaths.root(absolute) != nil,
              let at=date(value.observedAt),at>=observation.identity.bornAt,
              now.timeIntervalSince(at)>=(-2),now.timeIntervalSince(at)<=60,
              abs(modified.timeIntervalSince(at))<=10 else { return nil }
        // A CLI output declaration cannot be silently retargeted by metadata in a different root.
        if let root=observation.outputRoot,AppConfig.normalizedMacFolder(absolute) != root { return nil }
        return (value,at)
    }
    private static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count<=256 && !value.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains)
    }
    static func date(_ raw: String) -> Date? {
        let formatter=ISO8601DateFormatter();formatter.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        if let date=formatter.date(from:raw) { return date }
        formatter.formatOptions=[.withInternetDateTime];return formatter.date(from:raw)
    }
    func apply(to observation: inout NativeRenderObservation, at: Date) {
        observation.outputRoot=AppConfig.normalizedMacFolder(outputRoot)
        observation.runID=runID;observation.projectID=projectID;observation.workID=workID;observation.versionID=versionID
        observation.workType=workType.flatMap(RenderWorkType.init(rawValue:));observation.outputRole=outputRole
        let validTotal=total.flatMap { $0>0 && $0<=1_000_000 ? $0 : nil }
        let validCompleted=completed.flatMap { $0>=0 && $0<=1_000_000 && (validTotal == nil || $0<=validTotal!) ? $0 : nil }
        observation.declaredTotal=validTotal;observation.completed=validCompleted;observation.metadataObservedAt=at
        observation.stage="Métadonnées locales associées · activité à confirmer"
    }
}
