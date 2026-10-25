import Foundation

protocol RenderLibraryRemoteTransferring:Sendable {
    func configure(settings:RenderLibrarySettings) async throws
    func manifest(artifact:RenderRemoteArtifact,activation:Date,cursor:Int) async throws->RenderLibraryRemotePage
    func stage(artifact:RenderRemoteArtifact,activation:Date,destination:URL) async throws->RenderLibraryTransferProof
    func retire(artifact:RenderRemoteArtifact,activation:Date,transactionID:String,sha256:String) async throws->RenderRemoteReturn
    func restore(artifact:RenderRemoteArtifact,activation:Date,transactionID:String,sha256:String) async throws->RenderRemoteReturn
}
struct RenderLibraryTransferProof:Decodable {
    let sha256:String;let bytes:Int64;let localFile:String;let firstObservedAt:String;let secondObservedAt:String
}
struct RenderLibraryRemoteTransport:RenderLibraryRemoteTransferring {
    enum Failure:Error {case unavailable,refused,invalidProof}
    private struct Policy:Encodable {let schemaVersion=1;let enabled:Bool;let exportInMemory:Bool;let activatedAt:String;let expiresAt:String}
    private struct Request:Encodable {
        let operation:String;let activatedAt:String
        var artifact:RenderRemoteArtifact?=nil;var localFile:String?=nil;var transactionID:String?=nil;var sha256:String?=nil;var policy:Policy?=nil;var cursor:Int?=nil
    }
    private struct Restored:Decodable {let restored:Bool}
    private func run(_ request:Request)async throws->Data {
        guard let helper=Bundle.main.url(forResource:"render_library_transport",withExtension:"py") else{throw Failure.unavailable}
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let data=try encoder.encode(request)
        guard let json=String(data:data,encoding:.utf8),data.count<=16384,
              let response=await CollectorProcess.asyncRun(arguments:["--request-json",json],timeout:150,fixtureHelperURL:helper) else{throw Failure.refused}
        try Task.checkCancellation();return response
    }
    func configure(settings:RenderLibrarySettings)async throws {
        let active=settings.activatedAt ?? Date()
        let at=ISO8601DateFormatter().string(from:active)
        _ = try await run(Request(operation:"policy",activatedAt:at,policy:Policy(enabled:settings.mode == .managedLibrary,exportInMemory:settings.mode == .managedLibrary && settings.exportInMemory==true,activatedAt:at,expiresAt:ISO8601DateFormatter().string(from:Date().addingTimeInterval(120)))))
    }
    func manifest(artifact:RenderRemoteArtifact,activation:Date,cursor:Int)async throws->RenderLibraryRemotePage {
        let data=try await run(Request(operation:"manifest",activatedAt:ISO8601DateFormatter().string(from:activation),artifact:artifact,cursor:cursor))
        let page=try JSONDecoder().decode(RenderLibraryRemotePage.self,from:data)
        guard page.complete,page.descriptor.complete,page.descriptor.expectedCount>0,page.descriptor.expectedCount<=50_000,page.artifacts.count>0,page.artifacts.count<=32,Set(page.artifacts.map(\.id)).count==page.artifacts.count,
              page.artifacts.allSatisfy({$0.remote?.manifest==page.descriptor && $0.remote?.connectionScope==artifact.connectionScope && $0.id.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil}) else{throw Failure.invalidProof}
        return page
    }
    func stage(artifact:RenderRemoteArtifact,activation:Date,destination:URL)async throws->RenderLibraryTransferProof {
        let data=try await run(Request(operation:"stage",activatedAt:ISO8601DateFormatter().string(from:activation),artifact:artifact,localFile:destination.path))
        let p=try JSONDecoder().decode(RenderLibraryTransferProof.self,from:data)
        guard p.localFile==destination.path,p.bytes>0,p.sha256.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil,
              let a=RenderDate.parseOptional(p.firstObservedAt),let b=RenderDate.parseOptional(p.secondObservedAt),b.timeIntervalSince(a)>=8 else{throw Failure.invalidProof}
        return p
    }
    private func change(_ operation:String,_ a:RenderRemoteArtifact,_ activation:Date,_ transaction:String,_ hash:String)async throws->RenderRemoteReturn {
        let data=try await run(Request(operation:operation,activatedAt:ISO8601DateFormatter().string(from:activation),artifact:a,transactionID:transaction,sha256:hash))
        let proof=try JSONDecoder().decode(RenderRemoteReturn.self,from:data)
        guard proof.connectionScope==a.connectionScope,RenderContextPath.key(proof.originalPath)==RenderContextPath.key(a.path),proof.sha256==hash,proof.transactionID==transaction else{throw Failure.invalidProof}
        if operation=="restore" {guard try JSONDecoder().decode(Restored.self,from:data).restored else{throw Failure.invalidProof}}
        return proof
    }
    func retire(artifact:RenderRemoteArtifact,activation:Date,transactionID:String,sha256:String)async throws->RenderRemoteReturn {try await change("retire",artifact,activation,transactionID,sha256)}
    func restore(artifact:RenderRemoteArtifact,activation:Date,transactionID:String,sha256:String)async throws->RenderRemoteReturn {try await change("restore",artifact,activation,transactionID,sha256)}
}
