import Foundation

// Explicit private mapping. No producer/client path or business identity is built into the application.
struct NativeMetadataSourceConfig:Codable {
    let processIdentity:NativeProcessIdentity
    let scene:String
    let metadataPath:String
    let outputRoot:String
    let filenamePattern:String
    var plannedKey="planned"
    var completedKey="completed"
    var frameKey="frame"
    var secondsKey="seconds"
    var totalKey:String?=nil
    var maximumBytes=32*1024
    var exclusiveOutputScope=false
    var runID:String?=nil
    var projectID:String?=nil
    var workID:String?=nil
    var versionID:String?=nil
    var workType:RenderWorkType?=nil
}

extension NativeMetadataSourceConfig {
    private enum CodingKeys:String,CodingKey { case processIdentity,scene,metadataPath,outputRoot,filenamePattern,plannedKey,completedKey,frameKey,secondsKey,totalKey,maximumBytes,exclusiveOutputScope,runID,projectID,workID,versionID,workType }
    init(from decoder:Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        processIdentity=try c.decode(NativeProcessIdentity.self,forKey:.processIdentity)
        scene=try c.decode(String.self,forKey:.scene);metadataPath=try c.decode(String.self,forKey:.metadataPath)
        outputRoot=try c.decode(String.self,forKey:.outputRoot);filenamePattern=try c.decode(String.self,forKey:.filenamePattern)
        plannedKey=try c.decodeIfPresent(String.self,forKey:.plannedKey) ?? "planned"
        completedKey=try c.decodeIfPresent(String.self,forKey:.completedKey) ?? "completed"
        frameKey=try c.decodeIfPresent(String.self,forKey:.frameKey) ?? "frame"
        secondsKey=try c.decodeIfPresent(String.self,forKey:.secondsKey) ?? "seconds"
        totalKey=try c.decodeIfPresent(String.self,forKey:.totalKey)
        maximumBytes=try c.decodeIfPresent(Int.self,forKey:.maximumBytes) ?? 32*1024
        exclusiveOutputScope=try c.decodeIfPresent(Bool.self,forKey:.exclusiveOutputScope) ?? false
        runID=try c.decodeIfPresent(String.self,forKey:.runID);projectID=try c.decodeIfPresent(String.self,forKey:.projectID)
        workID=try c.decodeIfPresent(String.self,forKey:.workID);versionID=try c.decodeIfPresent(String.self,forKey:.versionID)
        workType=(try c.decodeIfPresent(String.self,forKey:.workType)).flatMap(RenderWorkType.init(rawValue:))
    }
}
