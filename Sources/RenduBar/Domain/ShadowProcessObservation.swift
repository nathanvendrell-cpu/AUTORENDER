import Foundation
import CryptoKit

struct ShadowProcessSnapshot:Codable {
    let schemaVersion:Int
    let observedAt:String
    let coverageComplete:Bool
    let observations:[ShadowProcessObservation]
    var connectionScope:String?=nil
    func validated(at now:Date) -> Bool {
        guard schemaVersion==1,let at=RenderDate.parseOptional(observedAt),at<=now,now.timeIntervalSince(at)<=120,
              observations.count<=128,observations.filter(\.isQualifiedActiveObservation).count<=50,
              Set(observations.map(\.id)).count==observations.count else{return false}
        return observations.allSatisfy{$0.validated(snapshotAt:at)}
    }
}

struct ShadowProcessObservation:Codable {
    let connectionScope:String
    let pid:Int32
    let birth:String
    let executable:String
    let engine:String
    let id:String
    let observedAt:String
    let qualified:Bool
    let evidence:String?
    let title:String
    let completedFrames:Int?
    let totalFrames:Int?
    var mediaPositionSeconds:Double?=nil
    var mediaDurationSeconds:Double?=nil
    var progressObservedAt:String?=nil
    var completedSignal:Bool?=nil
    var invocationToken:String?=nil
    var nativeState:String?=nil
    var renderStartedAt:String?=nil
    var currentFrame:Int?=nil
    var backgroundProcess:Bool?=nil
    var sourceContext:RenderSourceContext?=nil
    var writtenFrames:Int?=nil
    var processBirthToken:String?=nil
    var exportArtifact:RenderExportArtifact?=nil
    var outputManifest:RenderRemoteManifestDescriptor?=nil
    var isQualifiedActiveObservation:Bool {qualified && nativeState != "complete" && nativeState != "cancel" && completedSignal != true}

    func validated(snapshotAt:Date)->Bool {
        let normalized=executable.replacingOccurrences(of:"\\",with:"/").lowercased()
        var identity=connectionScope+"|"+String(pid)+"|"+birth+"|"+normalized
        if let invocationToken {identity += "|"+invocationToken}
        let digest=SHA256.hash(data:Data(identity.utf8)).map{String(format:"%02x",$0)}.joined()
        guard pid>0,["blender","ffmpeg"].contains(engine),ShadowFolderScanner.validRemotePath(executable),
              normalized.hasSuffix("/"+engine+".exe"),connectionScope.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil,
              id=="shadow:process:"+digest,let born=RenderDate.parseOptional(birth),born<=snapshotAt,
              let observed=RenderDate.parseOptional(observedAt),observed<=snapshotAt,snapshotAt.timeIntervalSince(observed)<=30,
              !title.isEmpty,title.utf8.count<=1024,!title.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains),
              (qualified ? ["render_command","static_producer","blender_handler"].contains(evidence ?? "") : evidence==nil) else{return false}
        if backgroundProcess==true {
            guard engine=="blender",invocationToken==nil,nativeState==nil,
                  let started=RenderDate.parseOptional(renderStartedAt),started>=born,started<=observed else{return false}
        } else if let invocationToken {
            guard engine=="blender",invocationToken.range(of:"^[a-f0-9]{32}$",options:.regularExpression) != nil,
                  ["active","unknown","complete","cancel"].contains(nativeState ?? ""),totalFrames==nil,
                  let started=RenderDate.parseOptional(renderStartedAt),started>=born,started<=observed,
                  (qualified ? evidence=="blender_handler" && nativeState != "unknown":nativeState=="unknown") else{return false}
        } else if nativeState != nil || renderStartedAt != nil || currentFrame != nil || evidence=="blender_handler" {return false}
        if let writtenFrames,!(0...1_000_000).contains(writtenFrames){return false}
        if let currentFrame,!(Int(Int32.min)...Int(Int32.max)).contains(currentFrame){return false}
        if let total=totalFrames,!(1...1_000_000).contains(total){return false}
        if let count=completedFrames,(count<0 || count>1_000_000 || totalFrames.map({count>$0})==true){return false}
        if !qualified && (completedFrames != nil || totalFrames != nil || completedSignal==true || mediaPositionSeconds != nil || mediaDurationSeconds != nil){return false}
        if let duration=mediaDurationSeconds,(!duration.isFinite || duration<=0 || duration>31_536_000){return false}
        if let position=mediaPositionSeconds,(!position.isFinite || position<0 || position>31_536_000 || mediaDurationSeconds.map({position>$0})==true){return false}
        if completedFrames != nil || mediaPositionSeconds != nil {
            guard let progress=RenderDate.parseOptional(progressObservedAt),progress>=born,progress<=observed else{return false}
        }
        if completedSignal==true && (totalFrames==nil || totalFrames != completedFrames){return false}
        return true
    }

    func dashboard(fresh:Bool,eta:Date?=nil,recentProgress:Date?=nil) -> RenderDashboardJob {
        let nativeComplete=qualified && nativeState=="complete"
        let cancelled=qualified && nativeState=="cancel"
        let complete=nativeComplete || (qualified && completedSignal==true && completedFrames==totalFrames && totalFrames != nil)
        var stage=qualified ? "Processus "+engine+" attribué · tâche de rendu/encodage" : "Processus "+engine+" candidat · rendu non attesté"
        if evidence=="blender_handler" {stage = nativeComplete ? "Rendu terminé · événement natif Blender" : (cancelled ? "Rendu annulé · événement natif Blender":"Rendu Blender · événement natif et heartbeat")}
        if let position=mediaPositionSeconds {stage += " · média traité "+String(format:"%.2f s",position)}
        if let duration=mediaDurationSeconds {stage += " / "+String(format:"%.2f s déclarées",duration)}
        if completedFrames==nil {stage += " · compteur de frames indisponible"}
        var job=RenderDashboardJob(id:id,title:engine+" · "+title,projectID:"shadow-process:"+connectionScope,source:.shadowMonitor,
            workType:nil,rawCount:completedFrames,postCount:nil,
            rawProgress:completedFrames.flatMap{n in totalFrames.flatMap{RenderProgress(completed:n,total:$0)}},postProgress:nil,
            totalProvenance:totalFrames==nil ? nil:"Limite de frames CLI explicite · rapport du processus associé",
            activity:complete ? .countsReached : (cancelled ? .stopped:(fresh && qualified ? .running:.unknown)),isFresh:fresh,observedAt:RenderDate.parseOptional(observedAt),
            lastActivity:RenderDate.parseOptional(progressObservedAt),historicalMedianSeconds:nil,sampledOutputsLastHour:nil,
            eta:fresh && qualified && !complete && !cancelled ? eta:nil,process:nil,gpu:nil,gpuRaw:nil,plans:[],tasks:[],stageDescription:stage,previewEntries:[])
        job.renderStartedAt=RenderDate.parseOptional(renderStartedAt);job.currentFrame=currentFrame
        job.sourceContext=sourceContext?.sanitized
        if job.sourceContext != nil {job.sourceContext?.namespace="shadow:"+connectionScope}
        if nativeComplete,let path=job.sourceContext?.outputPath,let token=invocationToken,let birth=processBirthToken,let start=renderStartedAt {
            job.remoteArtifact=RenderRemoteArtifact(connectionScope:connectionScope,path:path,processID:pid,birthToken:birth,invocationToken:token,startedAt:start,completedAt:progressObservedAt ?? observedAt,expectedSHA256:exportArtifact?.sanitized?.sha256)
        }
        job.outputAvailability=nativeComplete && writtenFrames==0 && exportArtifact?.sanitized==nil ? .inMemory:((nativeComplete && ((writtenFrames ?? 0)>0 || exportArtifact?.sanitized != nil) && job.sourceContext?.outputPath != nil) ? .fileAttested:.unknown)
        if nativeComplete {job.finalOutputProof = .nativeComplete;job.outputExpectedCount=outputManifest?.expectedCount ?? ((writtenFrames ?? 0)<=1 ? 1:nil);job.remoteArtifact?.manifest=outputManifest}
        job.libraryInvocationID=invocationToken ?? id
        job.nativeRenderOutcome=nativeComplete ? "complete":(cancelled ? "cancel":nil)
        job.singleStageRender=true
        job.retainedHistorical = !fresh
        job.taskQualification=fresh && qualified && !complete && !cancelled ? (evidence=="static_producer" ? .nativeProductionContract:.nativeRenderCommand):nil
        job.progressObservedAt=recentProgress
        job.workTitle=title;job.versionLabel=engine+" · PID "+String(pid)
        job.projectTitle="PC · processus observés"
        job.contextProvenance="Identité Windows PID/naissance/exécutable · commande ou producteur statique · aucun projet à enregistrer"
        return job
    }
}

struct RenderExportArtifact:Codable {
    var path:String="";var sha256:String="";var bytes:Int64=0
    private enum CodingKeys:String,CodingKey {case path,sha256,bytes}
    init(path:String,sha256:String,bytes:Int64){self.path=path;self.sha256=sha256;self.bytes=bytes}
    init(from decoder:Decoder)throws {guard let c=try? decoder.container(keyedBy:CodingKeys.self) else{return};path=(try? c.decode(String.self,forKey:.path)) ?? "";sha256=(try? c.decode(String.self,forKey:.sha256)) ?? "";bytes=(try? c.decode(Int64.self,forKey:.bytes)) ?? 0}
    var sanitized:Self? {guard RenderContextPath.absolute(path) != nil,bytes>0,bytes<=2_147_483_648,sha256.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil else{return nil};return self}
}
