import Foundation
import CryptoKit

struct ShadowDeclaredSource: Codable, Equatable {
    var id:String
    var launcherPath:String
    var scriptPath:String
    var postScriptPath:String
    var outputRoot:String
    var rawRoot:String
    var postRoot:String
    var plans:[String:[Int]]
    var label:String?
    var expectedScriptSHA256:String?
    var runToken:String?
}

struct ShadowRunEnvelope: Codable {
    let ok:Bool
    let observedAt:String
    let partial:Bool
    let runs:[ShadowObservedRun]
    var automaticSources:[ShadowAutomaticSource]? = nil
}
struct ShadowAutomaticSource:Codable {
    let source:ShadowDeclaredSource
    let runID:String
    let launcherHash:String
    let observedAt:String
    let claims:[ShadowObservedRun.Claim]
    func matches(_ run:ShadowObservedRun)->Bool {
        let normalized=source.launcherPath.replacingOccurrences(of:"\\",with:"/").lowercased()
        let key=SHA256.hash(data:Data(normalized.utf8)).map{String(format:"%02x",$0)}.joined()
        return source.id == "auto_"+String(key.prefix(24)) && source.expectedScriptSHA256 == run.scriptHash
            && run.matches(source) && runID == run.runID && launcherHash == run.launcherHash && observedAt == run.observedAt
            && !claims.isEmpty && claims == run.claims && run.provenance == "process_observed"
            && Set(run.phases)==Set(claims.map(\.phase)) && claims.allSatisfy {claim in
                guard let binding=claim.binding,binding.engine == "blender",binding.ownerVerified else{return false}
                func norm(_ value:String)->String {value.replacingOccurrences(of:"\\",with:"/").lowercased()}
                return norm(binding.scriptPath)==norm(claim.phase == "raw" ? source.scriptPath : source.postScriptPath)
                    && binding.scriptSHA256 == (claim.phase == "raw" ? run.scriptHash : run.postScriptHash)
                    && norm(binding.outputRoot)==norm(claim.phase == "raw" ? source.rawRoot : source.postRoot)
            }
    }
}
struct ShadowObservedRun: Codable {
    struct Frame:Codable {let stage:String;let name:String;let path:String;let bytes:Int64;let modified:String}
    struct Claim:Codable,Equatable {
        struct Binding:Codable,Equatable {let engine:String;let ownerVerified:Bool;let scriptPath:String;let scriptSHA256:String;let outputRoot:String}
        let pid:Int32;let birth:String;let phase:String;let plan:String;let context:String
        var binding:Binding? = nil
    }
    let title:String;let id:String;let runID:String;let scopeID:String;let sourceID:String;let provenance:String;let observedAt:String
    let launcherHash:String;let scriptHash:String;let postScriptHash:String
    let outputRoot:String;let rawRoot:String;let postRoot:String
    let total:Int;let rawCount:Int;let postCount:Int
    let plans:[String:[Int]]
    let planCounts:[String:[String:Int]]
    let missingRaw:[String];let missingPost:[String]
    let frames:[Frame];let claims:[Claim];let activity:String;let phases:[String];let processCoverage:Bool
    struct Diagnostic:Codable {let code:String;let plan:String;let observedAt:String}
    let diagnostics:[Diagnostic]
    let logs:[String:[String]]
    private static func hash(_ value:String)->String {SHA256.hash(data:Data(value.utf8)).map{String(format:"%02x",$0)}.joined()}
    func matches(_ source:ShadowDeclaredSource) -> Bool {
        func norm(_ path:String)->String {path.replacingOccurrences(of:"\\",with:"/").lowercased()}
        guard [source.launcherPath,source.scriptPath,source.postScriptPath,source.outputRoot,source.rawRoot,source.postRoot].allSatisfy(ShadowFolderScanner.validRemotePath),sourceID == source.id,plans == source.plans,
              norm(outputRoot) == norm(source.outputRoot),norm(rawRoot) == norm(source.rawRoot),norm(postRoot) == norm(source.postRoot),
              source.expectedScriptSHA256.map({$0.lowercased() == scriptHash}) ?? true,
              runID == scopeID else{return false}
        let identity:[Any]=[norm(source.launcherPath),norm(source.scriptPath),norm(source.postScriptPath),launcherHash,scriptHash,postScriptHash,plans,norm(outputRoot),source.runToken ?? ""]
        guard let bytes=try? JSONSerialization.data(withJSONObject:identity,options:[.sortedKeys,.withoutEscapingSlashes]),
              let value=String(data:bytes,encoding:.utf8) else{return false}
        return scopeID == Self.hash(value)
    }
    func qualifiedClaimsMatch(_ source:ShadowDeclaredSource)->Bool {
        claims.allSatisfy {claim in
            guard let binding=claim.binding,binding.engine == "blender",binding.ownerVerified else{return false}
            func norm(_ value:String)->String {value.replacingOccurrences(of:"\\",with:"/").lowercased()}
            return norm(binding.scriptPath)==norm(claim.phase == "raw" ? source.scriptPath : source.postScriptPath)
                && binding.scriptSHA256 == (claim.phase == "raw" ? scriptHash : postScriptHash)
                && norm(binding.outputRoot)==norm(claim.phase == "raw" ? source.rawRoot : source.postRoot)
        }
    }
    func validated() -> Bool {
        guard title.utf8.count<=256,!title.isEmpty,!title.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains),
              sourceID.range(of:"^[A-Za-z0-9_-]{1,80}$",options:.regularExpression) != nil,
              ["source_declared","process_observed"].contains(provenance),["unknown","running","resumeRequired","countsReached"].contains(activity),
              diagnostics.count<=32,logs.count<=65,logs.allSatisfy({key,lines in key.utf8.count<=80 && !key.contains("/") && !key.contains("\\") && lines.count<=8 && lines.allSatisfy{$0.utf8.count<=2048}}),
              id == "shadow:run:"+runID,runID.range(of:"^[0-9a-f]{64}$",options:.regularExpression) != nil,scopeID.range(of:"^[0-9a-f]{64}$",options:.regularExpression) != nil,
              total>0,total<=20_000,rawCount>=0,rawCount<=total,postCount>=0,postCount<=total,
              missingRaw.count==total-rawCount,missingPost.count==total-postCount,
              Set(missingRaw).count==missingRaw.count,Set(missingPost).count==missingPost.count,
              frames.count<=80,claims.count<=24,logs.count<=65,
              [outputRoot,rawRoot,postRoot].allSatisfy(ShadowFolderScanner.validRemotePath),
              RenderOrganization.isInside(rawRoot+"/__scope__",root:outputRoot),
              RenderOrganization.isInside(postRoot+"/__scope__",root:outputRoot),rawRoot.lowercased() != postRoot.lowercased(),
              RenderDate.parseOptional(observedAt) != nil,
              [launcherHash,scriptHash,postScriptHash].allSatisfy({$0.range(of:"^[0-9a-f]{64}$",options:.regularExpression) != nil}) else {return false}
        if activity == "countsReached" && (!processCoverage || !claims.isEmpty || rawCount != total || postCount != total || !missingRaw.isEmpty || !missingPost.isEmpty) {return false}
        if activity == "running" && (provenance != "process_observed" || claims.isEmpty) {return false}
        guard plans.count<=32,plans.count>0,plans.allSatisfy({key,range in key.range(of:"^[A-Za-z][A-Za-z0-9_-]{0,15}$",options:.regularExpression) != nil && range.count==2 && range[0]>=0 && range[1]<=1_000_000 && range[1]>=range[0] && range[1]-range[0]<20_000}),
              plans.values.reduce(0,{$0+$1[1]-$1[0]+1})==total,Set(planCounts.keys)==Set(plans.keys),
              plans.allSatisfy({ key,range in let counts=planCounts[key] ?? [:];return ["raw","post"].allSatisfy {role in guard let count=counts[role] else{return false};return count>=0 && count<=range[1]-range[0]+1}}),
              planCounts.values.reduce(0,{$0+($1["raw"] ?? 0)})==rawCount,planCounts.values.reduce(0,{$0+($1["post"] ?? 0)})==postCount else{return false}
        var numbers=Set<Int>();var expected=Set<String>()
        for (plan,range) in plans {
            for n in range[0]...range[1] {if !numbers.insert(n).inserted {return false};expected.insert(plan+"_"+String(format:"%04d",n)+".png")}
            let size=range[1]-range[0]+1
            if missingRaw.filter({$0.hasPrefix(plan+"_")}).count != size-(planCounts[plan]?["raw"] ?? 0) {return false}
            if missingPost.filter({$0.hasPrefix(plan+"_")}).count != size-(planCounts[plan]?["post"] ?? 0) {return false}
        }
        guard Set(missingRaw).isSubset(of:expected),Set(missingPost).isSubset(of:expected),
              Set(frames.map{$0.stage+"|"+$0.name}).count==frames.count,
              diagnostics.allSatisfy({$0.code=="memory_error" && plans[$0.plan] != nil && RenderDate.parseOptional($0.observedAt) != nil}) else{return false}
        return frames.allSatisfy { f in
            let root=f.stage == "raw" ? rawRoot : postRoot
            return expected.contains(f.name) && ["raw","post"].contains(f.stage) && f.bytes>0 && f.bytes<=512*1024*1024
                && RenderOrganization.isInside(f.path,root:root)
                && !f.name.contains("/") && !f.name.contains("\\")
                && f.path.replacingOccurrences(of:"\\",with:"/").split(separator:"/").last.map(String.init)==f.name
                && RenderDate.parseOptional(f.modified) != nil
        } && claims.allSatisfy {plans[$0.plan] != nil && $0.pid>0 && RenderDate.parseOptional($0.birth).map({$0 <= RenderDate.parse(observedAt).addingTimeInterval(60)}) == true && ["raw","post"].contains($0.phase) && $0.context.range(of:"^[0-9a-f]{64}$",options:.regularExpression) != nil}
    }
    func dashboard(fresh:Bool,stableFrames:Set<String>=[]) -> RenderDashboardJob {
        let running=fresh && activity == "running" && provenance == "process_observed" && !claims.isEmpty
        // Retain an already qualified technical terminal observation when its source becomes offline.
        // Unknown/counter-only observations remain unknown; no fresh worker or export is asserted.
        let historicalTerminal = activity == "countsReached" && validated() && processCoverage && claims.isEmpty
            && rawCount==total && postCount==total && missingRaw.isEmpty && missingPost.isEmpty
        let entries=frames.map { f in RenderEntry(id:"shadow-frame:"+Self.hash(runID+"|"+f.stage+"|"+f.path),source:.shadowFolder,
            job:title,filename:f.name,modified:RenderDate.parse(f.modified),state:stableFrames.contains(runID+"|"+f.path.lowercased()) ? .stable : .pending,path:f.path,previewURL:nil,monitorJobID:id) }
        var job=RenderDashboardJob(id:id,title:title,projectID:"shadow-source:"+sourceID,source:.shadowMonitor,
            workType:.video,rawCount:rawCount,postCount:postCount,rawProgress:RenderProgress(completed:rawCount,total:total),
            postProgress:RenderProgress(completed:postCount,total:total),totalProvenance:"Plan du lanceur déclaré · étapes distinctes",
            activity:running ? .running : (historicalTerminal ? .countsReached : (fresh && activity == "resumeRequired" && processCoverage && !diagnostics.isEmpty ? .resumeRequired : .unknown)),isFresh:fresh,observedAt:RenderDate.parseOptional(observedAt),lastActivity:entries.first?.modified,
            historicalMedianSeconds:nil,sampledOutputsLastHour:nil,eta:nil,historicalETA:nil,process:nil,gpu:nil,gpuRaw:nil,plans:plans.sorted{$0.key<$1.key}.flatMap { key,range in
                ["raw","post"].map {role in RenderDashboardPlan(id:key+" · "+(role=="raw" ? "brut" : "post"),completed:planCounts[key]?[role],total:range.count==2 ? range[1]-range[0]+1 : 0,team:nil)}
            },tasks:[],
            stageDescription:(fresh ? (provenance == "process_observed" ? "Processus associé observé" : "Source déclarée") : "Dernier relevé")
                + (running ? " · phase "+phases.joined(separator:", ") : (historicalTerminal ? " · sorties complètes antérieurement qualifiées, fin technique" : " · activité indéterminée, aucun worker attribué"))
                + (fresh && activity == "resumeRequired" ? " · incomplet, à reprendre" : "") + " · étapes brut/post distinctes" + (diagnostics.isEmpty ? "" : " · diagnostic mémoire daté "+diagnostics.map{$0.plan+" "+$0.observedAt}.joined(separator:", ")),previewEntries:Array(entries.prefix(2)))
        job.retainedHistorical = !fresh
        job.taskQualification=running && claims.allSatisfy({$0.binding?.ownerVerified == true && $0.binding?.engine == "blender"}) ? .attestedShadowRun : nil
        job.workID=nil;job.sourceWorkID=nil;job.workTitle=title;job.projectTitle=title
        job.versionID=runID;job.sourceVersionID=nil;job.versionLabel=title
        job.contextProvenance=job.stageDescription ?? "Source déclarée"
        job.openTargets=[rawRoot,postRoot].map { root in RenderFolderTarget(id:Self.hash(root),title:root==rawRoot ? "Images brutes" : "Images post",location:nil,remoteDisplay:root,isVerified:fresh,verifiedAt:fresh ? RenderDate.parseOptional(observedAt) : nil) }
        job.latestOutput=entries.first
        return job
    }
}
