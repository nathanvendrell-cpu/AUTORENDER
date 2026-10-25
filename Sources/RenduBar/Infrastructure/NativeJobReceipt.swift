import Foundation
import CryptoKit
import Darwin
import CoreFoundation

// Read-only adapter for the explicit job.json / frames_receipt.json producer contract.
// No Python execution, recursive Mac search, file movement or claim of verified output files.
final class NativeJobReceiptReader {
    enum Failure:Error {case contract,identity,changed,bounds}
    struct Value {
        let binding:NativeJobReceiptBinding
        let scene:String;let renderer:String;let outputRoot:String?
        let total:Int;let completed:Int;let at:Date;let state:String;let memoryFailure:Bool
        let timing:RenderFrameTiming?;let preview:RenderEntry?
        func apply(to observation:inout NativeRenderObservation,previous:(Int,Date)?=nil) {
            observation.frameTiming=timing;observation.receiptBoundPreview=true;observation.verifiedPreviewEntry=preview
            observation.jobDirectory=binding.directory;observation.scene=scene;observation.script=renderer
            observation.outputRoot=outputRoot;observation.outputPattern=nil
            observation.declaredTotal=total;observation.completed=completed;observation.metadataObservedAt=at
            observation.runID=binding.jobSHA256;observation.workType = total==1 ? .image:.video
            observation.progressProvenance="Reçu du producteur lié au manifeste, à la scène et au script · fichiers non vérifiés"
            observation.stableOutputCountVerified=false;observation.outputScopeIsExclusive=false
            observation.renderCommand=false;observation.taskQualification=nil;observation.metadataAdvanced=false
            if state=="RUNNING",observation.processPresent {
                observation.taskQualification = .nativeProductionContract
                observation.activityOverride = .running
                observation.stage="Rendu du producteur qualifié · processus et naissance corrélés"
                if let previous,completed>previous.0,at>previous.1,observation.observedAt.timeIntervalSince(at)<=20 {
                    observation.metadataAdvanced=true;observation.progressObservedAt=at
                    observation.stage += " · progression déclarée par le producteur"
                } else {observation.stage += " · aucune nouvelle frame déclarée"}
            } else if state=="RUNNING" || state=="STOPPED_OR_FAILED" || state=="FAILED" || state=="STOPPED" {
                observation.activityOverride = .resumeRequired
                observation.stage=state=="RUNNING" ? "Processus absent · rendu interrompu, reprise à confirmer":"Rendu arrêté ou en échec · à reprendre"
                if memoryFailure {observation.stage += " · mémoire GPU insuffisante (journal du job)"}
            } else {
                observation.activityOverride = .countsReached
                observation.stage="Frames déclarées terminées par le producteur · fichiers et export final non attestés"
            }
        }
    }
    private struct Stamp:Equatable {let device:UInt64;let inode:UInt64;let bytes:Int64;let seconds:Int64;let nanos:Int64;let changeSeconds:Int64;let changeNanos:Int64}
    private struct PreviewRecord {let frame:Int;let bytes:Int64;let sha:String;let seconds:Double?;var signature:String{sha+"|"+String(bytes)}}
    private struct PreviewCandidate {let record:PreviewRecord;let path:String;let stamp:Stamp}
    private struct PreviewScope {var known:[Int:String]=[:];var candidate:PreviewCandidate?;var verified:(String,Stamp,RenderEntry)?;var touched:Date}
    private var previewScopes:[String:PreviewScope]=[:]
    private var previewStatBudget=256,previewHashBudget=2
    private(set) var previewHashReads=0
    func beginCollection(){previewStatBudget=256;previewHashBudget=2}
    private static func seconds(_ raw:Any?)->Double? {
        guard let n=raw as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue.isFinite,n.doubleValue>0,n.doubleValue<=86_400 else{return nil}
        return n.doubleValue
    }
    private func preview(records:[PreviewRecord],binding:NativeJobReceiptBinding,root:String?,settings:[String:Any],now:Date,permit:RenderIOPermit?)throws->(RenderEntry?,Double?) {
        guard let root,root==URL(fileURLWithPath:binding.directory).appendingPathComponent("frames").path,!records.isEmpty,records.count<=2048 else{return (nil,nil)}
        let key=binding.identity.jobID+"|"+binding.jobSHA256
        var scope=previewScopes[key] ?? PreviewScope(touched:now);scope.touched=now
        let current=Dictionary(uniqueKeysWithValues:records.map{($0.frame,$0.signature)})
        scope.known=scope.known.filter{current[$0.key]==$0.value}
        if let candidate=scope.candidate {
            if let record=records.first(where:{$0.frame==candidate.record.frame}),record.signature==candidate.record.signature {
                scope.candidate=PreviewCandidate(record:record,path:candidate.path,stamp:candidate.stamp)
            } else {scope.candidate=nil;scope.verified=nil}
        }
        // Supported job/receipt layout, independent of project names. A filename is never sufficient:
        // exact receipt bytes + SHA256 + PNG envelope must also match before exposure.
        var inspected=0
        for record in records where scope.known[record.frame] != record.signature {
            try permit?.check();guard previewStatBudget>1,inspected<64 else{break}
            previewStatBudget-=1;inspected+=1
            let path=URL(fileURLWithPath:root).appendingPathComponent(String(format:"f_%04d.png",record.frame)).path
            guard let value=try? stamp(path),value.bytes==record.bytes else{continue}
            scope.known[record.frame]=record.signature
            if scope.candidate.map({value.seconds>$0.stamp.seconds || (value.seconds==$0.stamp.seconds && value.nanos>$0.stamp.nanos)}) ?? true {
                scope.candidate=PreviewCandidate(record:record,path:path,stamp:value);scope.verified=nil
            }
        }
        defer {
            if previewScopes.count>=16,previewScopes[key]==nil,let oldest=previewScopes.min(by:{$0.value.touched<$1.value.touched})?.key{previewScopes.removeValue(forKey:oldest)}
            previewScopes[key]=scope
        }
        guard scope.known.count==records.count,let candidate=scope.candidate,previewStatBudget>0 else{return (nil,nil)}
        previewStatBudget-=1
        guard let before=try? stamp(candidate.path),before==candidate.stamp else{scope.known.removeValue(forKey:candidate.record.frame);scope.candidate=nil;scope.verified=nil;return (nil,nil)}
        if let cached=scope.verified,cached.0==candidate.record.sha,cached.1==before {return (cached.2,candidate.record.seconds)}
        guard previewHashBudget>0 else{return (nil,nil)};previewHashBudget-=1
        let fd=open(candidate.path,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);guard fd>=0 else{return (nil,nil)};defer{close(fd)}
        var info=stat()
        guard fstat(fd,&info)==0,(info.st_mode & S_IFMT)==S_IFREG,UInt64(info.st_ino)==before.inode,UInt64(info.st_dev)==before.device,
              before.bytes<=128*1024*1024,let dimensions=NativePlannedFrameMetadata.pngEnvelope(fd:fd,bytes:before.bytes) else{return (nil,nil)}
        if settings["width"] != nil || settings["height"] != nil {
            guard let width=Self.integer(settings["width"]),let height=Self.integer(settings["height"]),width>0,height>0,
                  dimensions == [UInt32(width),UInt32(height)] else{return (nil,nil)}
        }
        var hash=SHA256(),buffer=[UInt8](repeating:0,count:1024*1024);var bytes:Int64=0
        while true {
            try permit?.check();let n=buffer.withUnsafeMutableBytes{Darwin.read(fd,$0.baseAddress,$0.count)}
            if n==0{break};if n<0{if errno==EINTR{continue};return (nil,nil)}
            bytes += Int64(n);guard bytes<=before.bytes else{return (nil,nil)};hash.update(data:Data(buffer.prefix(n)))
        }
        previewHashReads+=1
        guard bytes==before.bytes,try stamp(candidate.path)==before,hash.finalize().map({String(format:"%02x",$0)}).joined()==candidate.record.sha else{return (nil,nil)}
        let modified=Date(timeIntervalSince1970:Double(before.seconds)+Double(before.nanos)/1e9)
        let token=[key,candidate.path,candidate.record.sha,String(before.device),String(before.inode),String(before.bytes),String(before.seconds),String(before.nanos),String(before.changeSeconds),String(before.changeNanos)].joined(separator:"|")
        let id="mac:receipt-preview:"+SHA256.hash(data:Data(token.utf8)).map{String(format:"%02x",$0)}.joined()
        var entry=RenderEntry(id:id,source:.macFolder,job:"Blender",filename:URL(fileURLWithPath:candidate.path).lastPathComponent,modified:modified,state:.stable,path:candidate.path,previewURL:nil,monitorJobID:binding.identity.jobID)
        entry.localPreviewProof=RenderLocalPreviewProof(jobID:binding.identity.jobID,sha256:candidate.record.sha,
            stamp:RenderLibraryFileStamp(device:before.device,inode:before.inode,bytes:before.bytes,modifiedSeconds:before.seconds,modifiedNanoseconds:before.nanos),
            changedSeconds:before.changeSeconds,changedNanoseconds:before.changeNanos)
        scope.verified=(candidate.record.sha,before,entry)
        return (entry,candidate.record.seconds)
    }
    private var hashes:[String:(Stamp,String)]=[:]
    private var searches:[String:Date]=[:]
    private(set) var hashReads=0
    private func stamp(_ p:String)throws->Stamp {
        var s=stat();guard lstat(p,&s)==0,(s.st_mode & S_IFMT)==S_IFREG,s.st_size>=0 else{throw Failure.contract}
        return Stamp(device:UInt64(s.st_dev),inode:UInt64(s.st_ino),bytes:s.st_size,seconds:Int64(s.st_mtimespec.tv_sec),nanos:Int64(s.st_mtimespec.tv_nsec),changeSeconds:Int64(s.st_ctimespec.tv_sec),changeNanos:Int64(s.st_ctimespec.tv_nsec))
    }
    private func digest(_ path:String,maximum:Int64,check:()throws->Void)throws->String {
        try check();let before=try stamp(path);guard before.bytes<=maximum else{throw Failure.bounds}
        if let cached=hashes[path],cached.0==before {return cached.1}
        let fd=open(path,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);guard fd>=0 else{throw Failure.contract};defer{close(fd)}
        var info=stat();guard fstat(fd,&info)==0,UInt64(info.st_dev)==before.device,UInt64(info.st_ino)==before.inode else{throw Failure.changed}
        var hash=SHA256(),buffer=[UInt8](repeating:0,count:1024*1024);var length:Int64=0
        while true {
            try check();let n=buffer.withUnsafeMutableBytes{Darwin.read(fd,$0.baseAddress,$0.count)}
            if n==0 {break};if n<0 {if errno==EINTR{continue};throw Failure.contract}
            length += Int64(n);guard length<=maximum else{throw Failure.bounds};hash.update(data:Data(buffer.prefix(n)))
        }
        guard length==before.bytes,try stamp(path)==before else{throw Failure.changed}
        let value=hash.finalize().map{String(format:"%02x",$0)}.joined();hashReads += 1
        if hashes.count>=128 {hashes.removeAll()};hashes[path]=(before,value);return value
    }
    private static func sha(_ value:Any?)->String? {
        guard let value=value as? String,value.count==64,value.allSatisfy({$0.isASCII && ($0.isNumber || ("a"..."f").contains(String($0)))}) else{return nil};return value
    }
    private static func integer(_ value:Any?)->Int? {
        guard let value=value as? NSNumber,CFGetTypeID(value) != CFBooleanGetTypeID(),value.doubleValue.isFinite,value.doubleValue.rounded()==value.doubleValue,value.doubleValue>=0,value.doubleValue<=1_000_000_000 else{return nil};return value.intValue
    }
    private static func date(_ raw:Any?)->Date? {
        guard let raw=raw as? String else{return nil}
        let f=ISO8601DateFormatter();f.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        return f.date(from:raw) ?? ISO8601DateFormatter().date(from:raw)
    }
    private func object(_ file:URL,maximum:Int,permit:RenderIOPermit?)throws->[String:Any] {
        let data=try RenderRegularFile.read(file,maximumBytes:maximum,permit:permit,allowSymlink:false)
        guard let value=try JSONSerialization.jsonObject(with:data) as? [String:Any] else{throw Failure.contract};return value
    }
    func read(directory:String,identity:NativeProcessIdentity,scene:String,renderer:String,now:Date,binding:NativeJobReceiptBinding?=nil,permit:RenderIOPermit?=nil)throws->Value {
        try permit?.check()
        guard NativeProcessReader.producer(identity.executable)=="Blender",let root=NativeRenderPaths.absolute(directory),root==directory,
              let safeRoot=NativeRenderPaths.root(root),safeRoot==root else{throw Failure.contract}
        let url=URL(fileURLWithPath:root),jobFile=url.appendingPathComponent("job.json")
        let jobData=try RenderRegularFile.read(jobFile,maximumBytes:64*1024,permit:permit,allowSymlink:false)
        guard let job=try JSONSerialization.jsonObject(with:jobData) as? [String:Any],
              let manifestScene=job["scene"] as? String,let manifestScript=job["renderer"] as? String,
              NativeRenderPaths.absolute(manifestScene)==scene,NativeRenderPaths.absolute(manifestScript)==renderer,
              let sceneSHA=Self.sha(job["sceneSHA256"]),let scriptSHA=Self.sha(job["rendererSHA256"]),
              let settings=job["settings"] as? [String:Any],let total=Self.integer(settings["frames"]),total>0,total<=1_000_000,
              let created=Self.date(job["createdUTC"]),created<=now.addingTimeInterval(2),created<=identity.bornAt.addingTimeInterval(2),
              (job["blender"] as? String).flatMap({NativeRenderPaths.absolute($0)})==identity.executable else{throw Failure.contract}
        guard let sceneStamp=try? stamp(scene),let scriptStamp=try? stamp(renderer),
              Double(sceneStamp.seconds)+Double(sceneStamp.nanos)/1e9<=identity.bornAt.timeIntervalSince1970,
              Double(scriptStamp.seconds)+Double(scriptStamp.nanos)/1e9<=identity.bornAt.timeIntervalSince1970 else{throw Failure.changed}
        let jobSHA=SHA256.hash(data:jobData).map{String(format:"%02x",$0)}.joined()
        let admitted=NativeJobReceiptBinding(directory:root,identity:identity,jobSHA256:jobSHA,sceneSHA256:sceneSHA,rendererSHA256:scriptSHA)
        if let binding,admitted != binding {throw Failure.changed}
        guard try digest(scene,maximum:8*1024*1024*1024,check:{try permit?.check()})==sceneSHA,
              try digest(renderer,maximum:2*1024*1024,check:{try permit?.check()})==scriptSHA else{throw Failure.changed}
        let receipt=try object(url.appendingPathComponent("frames_receipt.json"),maximum:2*1024*1024,permit:permit)
        guard Self.sha(receipt["jobSHA256"])==jobSHA,Self.sha(receipt["sceneSHA256"])==sceneSHA,
              Self.integer(receipt["pid"])==Int(identity.pid),let at=Self.date(receipt["utc"]),
              at>=identity.bornAt,at<=now.addingTimeInterval(2),
              let state=receipt["state"] as? String,let count=Self.integer(receipt["completeFrames"]),count<=total,
              let actual=receipt["settings"] as? [String:Any],NSDictionary(dictionary:actual).isEqual(to:settings),
              let records=receipt["records"] as? [[String:Any]],records.count==count,records.count<=50_000 else{throw Failure.identity}
        var frames=Set<Int>(),previewRecords:[PreviewRecord]=[]
        var timingSum=0.0,timingCount=0
        let reuse=job["reusedNativeFrames"] as? [String:Any]
        let reused=Set((reuse?["frames"] as? [Any] ?? []).compactMap(Self.integer))
        let reuseKnown=job["reusedNativeFrames"]==nil || ((reuse?["frames"] as? [Any]).map{$0.count==reused.count}==true && reused.allSatisfy{(1...total).contains($0)})
        for record in records {
            try permit?.check()
            guard let frame=Self.integer(record["frame"]),frame>0,frame<=total,frames.insert(frame).inserted,
                  Self.sha(record["sha256"]) != nil,let bytes=Self.integer(record["bytes"]),bytes>0 else{throw Failure.contract}
            let elapsed=reuseKnown && !reused.contains(frame) ? Self.seconds(record["seconds"]):nil
            if let elapsed {timingSum+=elapsed;timingCount+=1}
            if records.count<=2048 {previewRecords.append(PreviewRecord(frame:frame,bytes:Int64(bytes),sha:Self.sha(record["sha256"])!,seconds:elapsed))}
        }
        let complete=state=="COMPLETE" || state=="COMPLETE_\(total)_REAL_FRAMES"
        guard ["RUNNING","STOPPED_OR_FAILED","STOPPED","FAILED"].contains(state) || (complete && count==total) else{throw Failure.contract}
        // Bounded tail of this exact producer log; no raw log content leaves the adapter.
        var memoryFailure=false
        if ["STOPPED_OR_FAILED","STOPPED","FAILED"].contains(state) {
            let log=url.appendingPathComponent("blender_stdout.txt").path
            if let stamp=try? stamp(log),Double(stamp.seconds)>=identity.bornAt.timeIntervalSince1970,
               abs(Double(stamp.seconds)-at.timeIntervalSince1970)<=60 {
                let fd=open(log,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)
                if fd>=0 {defer{close(fd)};var bytes=[UInt8](repeating:0,count:16*1024)
                    let n=bytes.withUnsafeMutableBytes{pread(fd,$0.baseAddress,$0.count,max(0,stamp.bytes-Int64($0.count)))}
                    if n>0,let text=String(bytes:bytes.prefix(n),encoding:.utf8){memoryFailure=text.contains("InsufficientMemory") || text.contains("out of memory")}
                }
            }
        }
        let framesRoot=NativeRenderPaths.root(url.appendingPathComponent("frames").path)
        let optionalPreview:(RenderEntry?,Double?)
        do {optionalPreview=try preview(records:previewRecords,binding:admitted,root:framesRoot,settings:settings,now:now,permit:permit)}
        catch {try permit?.check();optionalPreview=(nil,nil)}
        let (entry,latestSeconds)=optionalPreview
        let timing=timingCount>0 ? RenderFrameTiming(meanSeconds:timingSum/Double(timingCount),sampleCount:timingCount,latestSeconds:latestSeconds):nil
        return Value(binding:admitted,scene:scene,renderer:renderer,outputRoot:framesRoot,total:total,completed:count,at:at,state:state,memoryFailure:memoryFailure,timing:timing,preview:entry)
    }

    func read(binding:NativeJobReceiptBinding,now:Date,permit:RenderIOPermit?=nil)throws->Value {
        let job=try object(URL(fileURLWithPath:binding.directory).appendingPathComponent("job.json"),maximum:64*1024,permit:permit)
        guard let scene=job["scene"] as? String,let renderer=job["renderer"] as? String else{throw Failure.contract}
        return try read(directory:binding.directory,identity:binding.identity,scene:scene,renderer:renderer,now:now,binding:binding,permit:permit)
    }
    // Bounded breadth-first recovery inside a common scene/script root already in the catalogue.
    // Four roots, depth three, 64 directories and 128 entries per directory, once per minute.
    // PID/birth/executable must reconstruct the exact historical catalogue ID.
    func backfill(_ jobs:[RenderDashboardJob],now:Date,permit:RenderIOPermit?)throws->[NativeJobReceiptBinding] {
        var grouped:[String:[RenderDashboardJob]]=[:]
        for job in jobs.prefix(64) {
            guard job.id.hasPrefix("mac:native:"),job.renderStartedAt != nil,
                  let scene=job.sourceContext?.filePath,let renderer=job.sourceContext?.scriptPath,
                  let a=NativeRenderPaths.absolute(scene),let b=NativeRenderPaths.absolute(renderer) else{continue}
            let first=URL(fileURLWithPath:a).deletingLastPathComponent().pathComponents
            let second=URL(fileURLWithPath:b).deletingLastPathComponent().pathComponents
            let components=zip(first,second).prefix(while:{$0==$1}).map{$0.0}
            guard components.count>=5 else{continue};let root=NSString.path(withComponents:components)
            guard grouped.count<4 || grouped[root] != nil,NativeRenderPaths.root(root)==root else{continue}
            grouped[root,default:[]].append(job)
        }
        var result:[NativeJobReceiptBinding]=[]
        for (root,history) in grouped.sorted(by:{$0.key<$1.key}) {
            try permit?.check();guard searches[root].map({now.timeIntervalSince($0)>=60}) ?? true else{continue}
            searches[root]=now;var queue:[(String,Int)]=[(root,0)],visited=0
            while !queue.isEmpty && visited<64 {
                try permit?.check();let (directory,depth)=queue.removeFirst();visited += 1
                let url=URL(fileURLWithPath:directory)
                if let data=try? object(url.appendingPathComponent("job.json"),maximum:64*1024,permit:permit),
                   let scene=data["scene"] as? String,let renderer=data["renderer"] as? String,let executable=data["blender"] as? String,
                   let receipt=try? object(url.appendingPathComponent("frames_receipt.json"),maximum:2*1024*1024,permit:permit),
                   let pid=Self.integer(receipt["pid"]),pid>0,pid<=Int(Int32.max) {
                    for job in history where job.sourceContext?.filePath==scene && job.sourceContext?.scriptPath==renderer {
                        guard let born=job.renderStartedAt else{continue}
                        let rounded=Int64((born.timeIntervalSince1970*1_000_000).rounded())
                        for delta:Int64 in [-1,0,1] {
                            let micros=rounded+delta;guard micros>0 else{continue}
                            let identity=NativeProcessIdentity(pid:Int32(pid),birthSeconds:UInt64(micros/1_000_000),birthMicroseconds:UInt64(micros%1_000_000),executable:executable)
                            guard identity.jobID==job.id else{continue}
                            if let value=try? read(directory:directory,identity:identity,scene:scene,renderer:renderer,now:now,permit:permit) {result.append(value.binding)}
                        }
                    }
                    continue // A producer's frame tree is outside the recovery search.
                }
                guard depth<3,let stream=opendir(directory) else{continue}
                defer{closedir(stream)}
                var entries=0,children:[String]=[]
                while let row=readdir(stream),entries<128 {
                    try permit?.check();entries += 1
                    let name=withUnsafePointer(to:&row.pointee.d_name){$0.withMemoryRebound(to:CChar.self,capacity:Int(MAXPATHLEN)){String(cString:$0)}}
                    guard !name.hasPrefix("."),children.count<64 else{continue}
                    let child=url.appendingPathComponent(name).path;var info=stat()
                    if lstat(child,&info)==0,(info.st_mode & S_IFMT)==S_IFDIR {children.append(child)}
                }
                for child in children.sorted() where queue.count<64 {queue.append((child,depth+1))}
            }
        }
        if searches.count>64 {searches=[:]}
        return result
    }
}
