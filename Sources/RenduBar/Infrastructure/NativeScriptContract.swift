import Foundation
import CryptoKit
import Darwin

struct NativeScriptDescriptor:Codable {
    struct MetadataFingerprint:Codable {let device:UInt64;let inode:UInt64;let bytes:Int64;let modified:Double}
    struct Plan:Codable {
        let scriptSHA256:String;let scene:String;let metadataPath:String;let outputRoot:String
        let filenamePattern:String;let planned:[Int];let variant:String;let mode:String;let grammar:String
        let metadataFingerprint:MetadataFingerprint?
    }
    let mapping:NativeMetadataSourceConfig
    let descriptor:Plan
    var isDirectRender:Bool {descriptor.grammar=="direct_top_level_render_v1"}
    func validated(snapshot:NativeProcessSnapshot,observation:NativeRenderObservation)->Bool {
        if isDirectRender {
            return mapping.processIdentity==snapshot.identity && mapping.scene==observation.scene && descriptor.scene==observation.scene
                && descriptor.scriptSHA256.range(of:"^[0-9a-f]{64}$",options:.regularExpression) != nil
                && ((descriptor.mode=="still" && descriptor.planned==[1]) || (descriptor.mode=="animation" && descriptor.planned.isEmpty))
                && descriptor.metadataPath.isEmpty && mapping.metadataPath.isEmpty
                && mapping.outputRoot==descriptor.outputRoot && mapping.filenamePattern==descriptor.filenamePattern
                && (descriptor.filenamePattern.isEmpty || (NativeRenderPaths.absolute(descriptor.filenamePattern)==descriptor.filenamePattern && URL(fileURLWithPath:descriptor.filenamePattern).deletingLastPathComponent().path==descriptor.outputRoot))
        }

        guard mapping.processIdentity==snapshot.identity,mapping.scene==observation.scene,descriptor.scene==observation.scene,
              descriptor.grammar=="static_per_frame_python_v1",descriptor.scriptSHA256.range(of:"^[0-9a-f]{64}$",options:.regularExpression) != nil,
              mapping.metadataPath==descriptor.metadataPath,mapping.outputRoot==descriptor.outputRoot,mapping.filenamePattern==descriptor.filenamePattern,
              mapping.plannedKey=="planned",mapping.completedKey=="completed",mapping.frameKey=="frame",mapping.secondsKey=="seconds",
              descriptor.planned.count>0,descriptor.planned.count<=10000,Set(descriptor.planned).count==descriptor.planned.count,
              descriptor.planned.allSatisfy({NativePlannedFrameMetadata.filename(frame:$0,pattern:descriptor.filenamePattern) != nil}),
              [mapping.metadataPath,mapping.outputRoot].allSatisfy({$0.hasPrefix("/") && !$0.split(separator:"/").contains("..")}),
              [descriptor.variant,descriptor.mode].allSatisfy({$0.range(of:"^[A-Za-z0-9_-]{1,80}$",options:.regularExpression) != nil}) else{return false}
        return true
    }
    func matchesScript(_ path:String,permit:RenderIOPermit) throws -> Bool {
        let (data,proof)=try NativePlannedFrameMetadata.readSource(path,permit:permit)
        guard proof.modified<=mapping.processIdentity.bornAt else{return false}
        return SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()==descriptor.scriptSHA256
    }
    var versionID:String {
        let fields=[descriptor.scriptSHA256,descriptor.scene,descriptor.metadataPath,descriptor.outputRoot,descriptor.filenamePattern,descriptor.variant,descriptor.mode]
        let data=(try? JSONSerialization.data(withJSONObject:[fields,descriptor.planned],options:[.sortedKeys,.withoutEscapingSlashes])) ?? Data()
        return SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
    }
    var projectTitle:String {"Source · "+URL(fileURLWithPath:descriptor.outputRoot).deletingLastPathComponent().deletingLastPathComponent().lastPathComponent}
    var componentTitle:String {descriptor.variant.replacingOccurrences(of:"_",with:" ")}
    var versionLabel:String {descriptor.mode.replacingOccurrences(of:"_",with:" ")}
}

protocol NativeScriptContractReading {
    func infer(_ snapshot:NativeProcessSnapshot,observation:NativeRenderObservation,permit:RenderIOPermit) throws -> NativeScriptDescriptor?
}
final class NativeScriptContractReader:NativeScriptContractReading {
    private enum Cached {case supported(NativeScriptDescriptor),unsupported}
    private var cache:[String:Cached]=[:]
    private let cacheLock=NSLock()
    private var invocations=0
    var helperInvocationCount:Int {cacheLock.lock();defer{cacheLock.unlock()};return invocations}
    private func remember(_ key:String,_ value:Cached) {
        cacheLock.lock();defer{cacheLock.unlock()}
        if cache.count>=64,cache[key]==nil,let victim=cache.keys.first{cache.removeValue(forKey:victim)}
        cache[key]=value
    }

    let helper:URL?
    init(helper:URL?=nil){self.helper=helper}
    func infer(_ snapshot:NativeProcessSnapshot,observation:NativeRenderObservation,permit:RenderIOPermit) throws -> NativeScriptDescriptor? {
        try permit.check()
        guard let script=observation.script,let scene=observation.scene,let args=snapshot.arguments,
              let helper=helper ?? Bundle.main.url(forResource:"native_script_contract",withExtension:"py") else{return nil}
        let (source,proof)=try NativePlannedFrameMetadata.readSource(script,permit:permit)
        guard proof.modified<=snapshot.identity.bornAt else{return nil}
        let hash=SHA256.hash(data:source).map{String(format:"%02x",$0)}.joined()
        let keyData=try JSONSerialization.data(withJSONObject:[hash,scene,script,snapshot.identity.executable,args,proof.device,proof.inode,URL(fileURLWithPath:script).resolvingSymlinksInPath().path])
        let key=SHA256.hash(data:keyData).map{String(format:"%02x",$0)}.joined()
        cacheLock.lock();let cached=cache[key];cacheLock.unlock()
        if let cached {
            switch cached {
            case .unsupported:return nil
            case .supported(let prior):
                let old=prior.mapping
                let mapping=NativeMetadataSourceConfig(processIdentity:snapshot.identity,scene:old.scene,metadataPath:old.metadataPath,outputRoot:old.outputRoot,filenamePattern:old.filenamePattern,workType:.video)
                let result=NativeScriptDescriptor(mapping:mapping,descriptor:prior.descriptor)
                guard result.descriptor.scriptSHA256==hash,result.validated(snapshot:snapshot,observation:observation) else{throw NativePlannedFrameMetadata.Failure.mapping}
                return result
            }
        }
        let identity=try JSONSerialization.jsonObject(with:JSONEncoder().encode(snapshot.identity))
        let data=try JSONSerialization.data(withJSONObject:["identity":identity,"arguments":args,"script":script,"scene":scene,"sameUser":true,"staticOnly":true])
        guard data.count<=131072 else{return nil}
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("autoren-native-contract-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        defer{try? FileManager.default.removeItem(at:directory)}
        let input=directory.appendingPathComponent("input");let output=directory.appendingPathComponent("output")
        try data.write(to:input);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:input.path)
        guard FileManager.default.createFile(atPath:output.path,contents:nil,attributes:[.posixPermissions:0o600]) else{return nil}
        let stdin=try FileHandle(forReadingFrom:input);let stdout=try FileHandle(forWritingTo:output)
        defer{try? stdin.close();try? stdout.close()}
        let process=Process();process.executableURL=URL(fileURLWithPath:FileManager.default.fileExists(atPath:"/opt/homebrew/bin/python3") ? "/opt/homebrew/bin/python3" : "/usr/bin/python3")
        process.arguments=["-B",helper.path];process.standardInput=stdin;process.standardOutput=stdout;process.standardError=FileHandle.nullDevice
        try permit.check();cacheLock.lock();invocations+=1;cacheLock.unlock();try process.run()
        defer{
            if process.isRunning {process.terminate();let deadline=Date().addingTimeInterval(0.2);while process.isRunning && Date()<deadline{usleep(5000)};if process.isRunning{kill(process.processIdentifier,SIGKILL)}}
            process.waitUntilExit()
        }
        let deadline=Date().addingTimeInterval(1)
        while process.isRunning {try permit.check();if Date()>=deadline{throw RenderIOFailure.deadline};usleep(5000)}
        process.waitUntilExit();try permit.check()
        guard process.terminationStatus==0 else{throw NativePlannedFrameMetadata.Failure.metadata}
        let bytes=try RenderRegularFile.read(output,maximumBytes:64*1024,permit:permit,allowSymlink:false)
        struct Envelope:Decodable {let ok:Bool;let result:NativeScriptDescriptor?;let reason:String?}
        guard let envelope=try? JSONDecoder().decode(Envelope.self,from:bytes) else{throw NativePlannedFrameMetadata.Failure.metadata}
        if !envelope.ok {if envelope.reason=="Unavailable"{throw NativePlannedFrameMetadata.Failure.metadata};remember(key,.unsupported);return nil}
        guard let result=envelope.result,result.validated(snapshot:snapshot,observation:observation) else{throw NativePlannedFrameMetadata.Failure.mapping}
        guard result.descriptor.scriptSHA256==hash else{throw NativePlannedFrameMetadata.Failure.unstable}
        remember(key,.supported(result))
        return result
    }
}
