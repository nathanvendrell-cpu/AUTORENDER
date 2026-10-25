import Foundation

enum RenderFinalOutputProof:String,Codable {case nativeComplete,verifiedCounters,scriptFinalContract}
struct RenderRemoteManifestDescriptor:Codable,Equatable {
    let id:String;let indexPath:String;let sha256:String;let expectedCount:Int;let complete:Bool
}
struct RenderScriptFinalProof:Codable,Equatable {
    let runID:String;let launcherPath:String;let launcherSHA256:String
    let scriptPath:String;let scriptSHA256:String;let postScriptPath:String;let postScriptSHA256:String
    let rawRoot:String;let postRoot:String;let plans:[String:[Int]]
}
struct RenderLibraryArtifact:Codable,Identifiable {
    let id:String;let path:String;var frame:Int?=nil
    var bytes:Int64?=nil;var modifiedNanoseconds:Int64?=nil
    var remote:RenderRemoteArtifact?=nil
}
struct RenderLibraryManifestCheckpoint:Codable {
    let id:String;let jobID:String;let invocationID:String;let expectedCount:Int
    var complete:Bool;var listingComplete:Bool;var nextCursor:Int
    var processedCursor:Int=0
    var registeredCount:Int=0;var movedCount:Int=0
    var remote:RenderRemoteManifestDescriptor?=nil
    var contextJob:RenderDashboardJob?=nil
}
struct RenderLibraryRemotePage:Decodable {
    let descriptor:RenderRemoteManifestDescriptor;let artifacts:[RenderLibraryArtifact];let nextCursor:Int?;let complete:Bool
}
struct RenderLibraryManifestItem:Codable {
    let manifestID:String;let position:Int;let artifact:RenderLibraryArtifact
}
enum RenderArtifactPattern {
    static func matches(_ path:String,pattern:String)->Bool {
        guard path.hasPrefix("/"),pattern.hasPrefix("/"),URL(fileURLWithPath:path).deletingLastPathComponent()==URL(fileURLWithPath:pattern).deletingLastPathComponent() else{return false}
        let p=(pattern as NSString).lastPathComponent,n=(path as NSString).lastPathComponent
        guard let expression=try? NSRegularExpression(pattern:"#+|%0?[0-9]*d") else{return false}
        let tokens=expression.matches(in:p,range:NSRange(p.startIndex...,in:p))
        if tokens.isEmpty{return n==p};guard tokens.count==1,let range=Range(tokens[0].range,in:p) else{return false}
        let before=String(p[..<range.lowerBound]),after=String(p[range.upperBound...])
        guard n.hasPrefix(before),n.hasSuffix(after),n.count>before.count+after.count else{return false}
        let middle=n.dropFirst(before.count).dropLast(after.count);let digits=middle.hasPrefix("-") ? middle.dropFirst():middle[...]
        return !digits.isEmpty && digits.allSatisfy{$0.isASCII && $0.isNumber}
    }
}

struct RenderLibraryJobPage {let records:[RenderLibraryRecord];let nextCursor:String?}
struct RenderLibraryLocation {let fileURL:URL?;let remoteDisplay:String?;let classified:Bool}
