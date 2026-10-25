import Foundation

enum RenderLibraryMode:String,Codable,CaseIterable {case catalogueOnly,managedLibrary
    var title:String {self == .catalogueOnly ? "Suivi et catalogue":"Bibliothèque gérée"}
}
struct RenderLibrarySettings:Codable,Equatable {
    var mode:RenderLibraryMode
    var rootPath:String
    var activatedAt:Date?
    var exportInMemory:Bool?=nil
    static let defaultRoot=(FileManager.default.urls(for:.moviesDirectory,in:.userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser).appendingPathComponent("AUTORENDER").path
    static let observation=Self(mode:.catalogueOnly,rootPath:defaultRoot,activatedAt:nil)
}
enum RenderLibraryState:String,Codable {case inMemory,needsClassification,previewOnly,awaitingTransfer,ready,moved,copiedSourceKept,conflict,undone,failed}
struct RenderLibraryFileStamp:Codable,Equatable {
    let device:UInt64;let inode:UInt64;let bytes:Int64;let modifiedSeconds:Int64;let modifiedNanoseconds:Int64
    static func read(_ url:URL)throws->Self {
        var info=stat();guard lstat(url.path,&info)==0,(info.st_mode & S_IFMT)==S_IFREG else{throw Failure.invalidFile}
        return Self(device:UInt64(info.st_dev),inode:UInt64(info.st_ino),bytes:Int64(info.st_size),modifiedSeconds:Int64(info.st_mtimespec.tv_sec),modifiedNanoseconds:Int64(info.st_mtimespec.tv_nsec))
    }
    enum Failure:Error {case invalidFile}
}
struct RenderLibraryCandidate:Codable {
    let id:String
    let jobID:String
    let localFile:URL
    let originalRemotePath:String?
    let runStartedAt:Date?
    let firstObservedAt:Date
    let secondObservedAt:Date
    let firstStamp:RenderLibraryFileStamp
    let secondStamp:RenderLibraryFileStamp
    let finalStageAttested:Bool
    let type:String
    let take:String
    var expectedSHA256:String?=nil
}
struct RenderLibraryPlan:Codable {
    let id:String
    let candidate:RenderLibraryCandidate
    let target:URL?
    let state:RenderLibraryState
    let reason:String
    let activationAt:Date?
}
struct RenderLibraryApproval {
    let planIDs:Set<String>
    let allowLegacy:Bool
    let allowLocalMove:Bool
    init(planIDs:Set<String>,allowLegacy:Bool=false,allowLocalMove:Bool=false){self.planIDs=planIDs;self.allowLegacy=allowLegacy;self.allowLocalMove=allowLocalMove}
}
struct RenderLibraryRecord:Codable,Identifiable {
    let id:String;let plan:RenderLibraryPlan;let at:Date
    var state:RenderLibraryState
    var sha256:String
    var detail:String
    var returnPath:URL?=nil
    var tempPath:URL?=nil
    var libraryID:String?=nil
    var libraryRoot:String?=nil
    var phase:RenderLibraryPhase?=nil
    var moveApproved:Bool?=nil
    var targetStamp:RenderLibraryFileStamp?=nil
    var tempStamp:RenderLibraryFileStamp?=nil
    var remoteReturn:RenderRemoteReturn?=nil
    var remoteArtifact:RenderRemoteArtifact?=nil
    var remoteTransactionID:String?=nil
    var contextJob:RenderDashboardJob?=nil
    var manifestID:String?=nil
    var restoredSourceStamp:RenderLibraryFileStamp?=nil
}


enum RenderLibraryPhase:String,Codable {case prepared,staged,linked,sourceHeld,complete,remotePrepared,remoteUndoPrepared,remoteRestored,undoPrepared,undoRestored,undone,failed}

enum RenderOutputAvailability:String,Codable {case inMemory,fileAttested,unknown}

struct RenderRemoteArtifact:Codable,Equatable {
    let connectionScope:String
    var path:String
    let processID:Int32
    let birthToken:String
    var invocationToken:String
    var startedAt:String
    let completedAt:String
    var expectedSHA256:String?=nil
    var manifest:RenderRemoteManifestDescriptor?=nil
    var manifestPagePath:String?=nil
    var manifestPageSHA256:String?=nil
    var scriptProof:RenderScriptFinalProof?=nil
}
struct RenderRemoteReturn:Codable,Equatable {
    let originalPath:String
    let returnPath:String
    let sha256:String
    let transactionID:String
    let connectionScope:String
}
