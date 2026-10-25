import Foundation

struct RenderLibraryActivity:Identifiable {let id:String;let state:RenderLibraryState;let detail:String}
struct RenderLibraryCycleResult {let records:[RenderLibraryRecord];let activities:[RenderLibraryActivity];let changed:Bool}

// Adopted observation cycle only. Every artifact has its own durable transaction.
actor RenderLibraryCoordinator {
    private let engine:ManagedRenderLibrary
    private let remote:any RenderLibraryRemoteTransferring
    private let lifetime:RenderTaskLifetime
    private struct Seen {let stamp:RenderLibraryFileStamp;let at:Date}
    private var seen:[String:Seen]=[:],retryAfter:[String:Date]=[:]
    private var completed=Set<String>()
    private var configured:RenderLibrarySettings?,policyRetry=Date.distantPast,policyRenewAt=Date.distantPast
    init(engine:ManagedRenderLibrary,lifetime:RenderTaskLifetime,remote:any RenderLibraryRemoteTransferring=RenderLibraryRemoteTransport()){self.engine=engine;self.lifetime=lifetime;self.remote=remote}
    func configurePolicy(settings:RenderLibrarySettings)async throws {
        try lifetime.check();try Task.checkCancellation();try await remote.configure(settings:settings)
        configured=settings;policyRenewAt=Date().addingTimeInterval(60)
    }
    private func retire(_ r:RenderLibraryRecord,artifact:RenderRemoteArtifact,settings:RenderLibrarySettings)async throws->RenderLibraryRecord {
        guard let active=r.plan.activationAt,active==settings.activatedAt else{throw ManagedRenderLibrary.Failure.notApproved}
        let prepared=try await engine.prepareRemoteRetirement(r.id,artifact:artifact,settings:settings)
        let proof=try await remote.retire(artifact:artifact,activation:active,transactionID:prepared.remoteTransactionID!,sha256:prepared.sha256)
        let result=try await engine.commitRemoteRetirement(r.id,proof:proof,settings:settings)
        try await engine.settleManifest(result,settings:settings);try await engine.releaseStaging(result,settings:settings);return result
    }
    func cycle(jobs:[RenderDashboardJob],settings:RenderLibrarySettings,now:Date=Date(),contextConfig:AppConfig?=nil,remoteConnectionExpected:Bool=false,remoteMonitoringEnabled:Bool=true)async->RenderLibraryCycleResult {
        guard settings.mode == .managedLibrary,let active=settings.activatedAt,lifetime.isOpen,!Task.isCancelled else{return .init(records:[],activities:[],changed:false)}
        var activities:[RenderLibraryActivity]=[],changed=false
        let recoveries=(try? await engine.pendingRecovery(settings:settings,limit:20)) ?? []
        for r in recoveries {
            if !remoteMonitoringEnabled,r.remoteArtifact != nil {continue}
            guard lifetime.isOpen,!Task.isCancelled else{break}
            do {
                let recovered:RenderLibraryRecord
                if r.phase == .remotePrepared,let a=r.remoteArtifact {recovered=try await retire(r,artifact:a,settings:settings)}
                else if r.phase == .remoteRestored {recovered=try await engine.finishRestoredRemoteUndo(r.id,settings:settings)}
                else if r.phase == .remoteUndoPrepared {recovered=try await undo(r.id,approvedRecordID:r.id,settings:settings)}
                else {recovered=try await engine.recover(r.id,approvedRecordID:r.id,settings:settings)}
                try await engine.settleManifest(recovered,settings:settings);changed=true
            }catch{activities.append(.init(id:r.id,state:.failed,detail:"Transaction interrompue · reprise non confirmée"))}
        }
        if remoteMonitoringEnabled,(configured != settings || now>=policyRenewAt),now>=policyRetry,(remoteConnectionExpected || configured != nil || jobs.contains(where:{$0.source.isShadow})) {
            do{try await configurePolicy(settings:settings)}catch{policyRetry=now.addingTimeInterval(60);activities.append(.init(id:"policy",state:.failed,detail:"Politique PC non confirmée"))}
        }
        // Admit every eligible observed job before the native ring rotates. Indexed queue survives absence/restart.
        for job in jobs {do{try await engine.enqueueManifest(job:job,settings:settings)}catch{activities.append(.init(id:job.id,state:.awaitingTransfer,detail:"Manifeste non enregistré · reprise requise"))}}
        for job in jobs where job.isTerminalRender && job.finalOutputProof != nil && job.outputAvailability != .inMemory && (job.outputExpectedCount==nil || job.outputAvailability != .fileAttested) {activities.append(.init(id:job.id,state:.awaitingTransfer,detail:"Manifeste complet des sorties encore indisponible"))}
        for job in jobs where job.outputAvailability == .inMemory {activities.append(.init(id:job.id,state:.inMemory,detail:"Render Result en mémoire · aucun export importable confirmé"))}
        let queued=(try? await engine.pendingManifestJobs(settings:settings)) ?? []
        for pending in queued {
            let job=contextConfig.map{RenderContextResolver(config:$0).apply(pending)} ?? pending
            if !remoteMonitoringEnabled,job.source.isShadow {continue}
            try? await engine.touchManifest(job,settings:settings) // Round-robin fairness, including blocked contexts.
            guard lifetime.isOpen,!Task.isCancelled else{break}
            guard let started=job.renderStartedAt,started>=active,job.isTerminalRender else{continue}
            if let retry=retryAfter[job.id],retry>now {continue}
            if job.outputAvailability == .inMemory {activities.append(.init(id:job.id,state:.inMemory,detail:"Render Result en mémoire · aucun export importable confirmé"));continue}
            guard job.contextAssignment == .assigned,job.hasVerifiedProjectContext==true,job.sceneID != nil,job.libraryVersion != nil else{activities.append(.init(id:job.id,state:.needsClassification,detail:"À classer · projet/scène/version à confirmer"));continue}
            guard job.finalOutputProof != nil else{activities.append(.init(id:job.id,state:.previewOnly,detail:"Preuve de fin compatible absente"));continue}
            do {
                var m=try await engine.prepareManifest(job:job,settings:settings)
                if completed.contains(m.id) {activities.append(.init(id:job.id,state:.moved,detail:"\(m.expectedCount)/\(m.expectedCount) sorties déplacées et vérifiées"));continue}
                if !m.listingComplete,m.nextCursor<=m.processedCursor,let a=job.remoteArtifact {
                    var request=a;request.manifest=m.remote ?? a.manifest
                    let page=try await remote.manifest(artifact:request,activation:active,cursor:m.nextCursor)
                    m=try await engine.appendRemoteManifest(page,job:job,settings:settings)
                }
                let items=try await engine.manifestPage(m.id,after:m.processedCursor,settings:settings)
                // Observe the entire small local page together; never skip an unstable earlier artifact.
                for item in items where item.artifact.remote==nil {
                    if let stamp=try? RenderLibraryFileStamp.read(URL(fileURLWithPath:item.artifact.path)),seen[item.artifact.id]?.stamp != stamp {seen[item.artifact.id]=Seen(stamp:stamp,at:now)}
                }
                for item in items {
                    try lifetime.check();try Task.checkCancellation()
                    var record=try await engine.recordForArtifact(jobID:job.id,artifactID:item.artifact.id,settings:settings)
                    if record?.phase == .undone {m=try await engine.advanceManifest(m.id,processed:item.position+1,settings:settings);continue}
                    if record==nil {
                        let c:RenderLibraryCandidate
                        if let artifact=item.artifact.remote {
                            let staging=URL(fileURLWithPath:settings.rootPath).appendingPathComponent(".autoren-staging");try RenderLibraryStore.directories(staging,create:true)
                            let ext=(artifact.path.replacingOccurrences(of:"\\",with:"/") as NSString).pathExtension.lowercased(),file=staging.appendingPathComponent(item.artifact.id+"."+ext)
                            let proof=try await remote.stage(artifact:artifact,activation:active,destination:file),stamp=try RenderLibraryFileStamp.read(file)
                            c=RenderLibraryCandidate(id:item.artifact.id,jobID:job.id,localFile:file,originalRemotePath:artifact.path,runStartedAt:started,firstObservedAt:RenderDate.parseOptional(proof.firstObservedAt)!,secondObservedAt:RenderDate.parseOptional(proof.secondObservedAt)!,firstStamp:stamp,secondStamp:stamp,finalStageAttested:true,type:ext,take:(RenderContextPath.leaf(item.artifact.path) as NSString).deletingPathExtension,expectedSHA256:proof.sha256)
                        }else{
                            let file=URL(fileURLWithPath:item.artifact.path),stamp=try RenderLibraryFileStamp.read(file)
                            guard let first=seen[item.artifact.id],first.stamp==stamp else{seen[item.artifact.id]=Seen(stamp:stamp,at:now);break}
                            guard now.timeIntervalSince(first.at)>=8 else{break}
                            c=RenderLibraryCandidate(id:item.artifact.id,jobID:job.id,localFile:file,originalRemotePath:nil,runStartedAt:started,firstObservedAt:first.at,secondObservedAt:now,firstStamp:first.stamp,secondStamp:stamp,finalStageAttested:true,type:file.pathExtension,take:(file.lastPathComponent as NSString).deletingPathExtension)
                        }
                        let p=await engine.preview(job:job,candidate:c,settings:settings);guard p.state == .ready else{throw ManagedRenderLibrary.Failure.notFinal}
                        let r=try await engine.execute(p,approval:.init(planIDs:[p.id],allowLocalMove:c.originalRemotePath==nil),settings:settings)
                        record=try await engine.attachManifest(r,manifestID:m.id,settings:settings);changed=true
                    }
                    if let r=record,r.phase == .complete,r.state == .copiedSourceKept,let a=item.artifact.remote {record=try await retire(r,artifact:a,settings:settings);changed=true}
                    if let r=record,r.phase == .complete {try await engine.settleManifest(r,settings:settings);m=try await engine.advanceManifest(m.id,processed:item.position+1,settings:settings);seen.removeValue(forKey:item.artifact.id)}
                }
                if let refreshed=try await engine.manifestCheckpoint(m.id,settings:settings){m=refreshed}
                let whole=try await engine.wholeManifestMoved(m.id,settings:settings)
                if whole {if completed.count>=256{completed.removeAll()};completed.insert(m.id)}
                let state:RenderLibraryState=whole ? .moved:(m.listingComplete && m.registeredCount==m.expectedCount ? .copiedSourceKept:.awaitingTransfer)
                activities.append(.init(id:job.id,state:state,detail:"\(m.movedCount)/\(m.expectedCount) sorties déplacées et vérifiées · \(m.registeredCount) copies classées"))
            }catch{retryAfter[job.id]=now.addingTimeInterval(60);activities.append(.init(id:job.id,state:.awaitingTransfer,detail:"Manifeste ou transfert incomplet · aucune fin globale affirmée"))}
        }
        if seen.count>512 {seen=[:]} // Bounded working page, never a history-wide cache.
        let keep=Set(queued.map(\.id));retryAfter=retryAfter.filter{keep.contains($0.key)}
        return .init(records:(try? await engine.loadRecent(settings:settings)) ?? [],activities:Array(activities.suffix(200)),changed:changed)
    }
    func undo(_ id:String,approvedRecordID:String,settings:RenderLibrarySettings,remoteMonitoringEnabled:Bool=true)async throws->RenderLibraryRecord {
        try lifetime.check();try Task.checkCancellation()
        if !remoteMonitoringEnabled {
            guard let stored=try await engine.recordByID(id,settings:settings),stored.remoteArtifact==nil,stored.plan.candidate.originalRemotePath==nil else{throw ManagedRenderLibrary.Failure.notApproved}
        }
        let r=try await engine.prepareRemoteUndo(id,approvedRecordID:approvedRecordID,settings:settings)
        var result:RenderLibraryRecord
        if r.phase == .remoteRestored {result=try await engine.finishRestoredRemoteUndo(r.id,settings:settings)}
        else if let a=r.remoteArtifact,let tx=r.remoteTransactionID,let active=r.plan.activationAt {let p=try await remote.restore(artifact:a,activation:active,transactionID:tx,sha256:r.sha256);result=try await engine.completeRemoteUndo(id,proof:p,settings:settings)}
        else{result=try await engine.undo(id,approvedRecordID:approvedRecordID,settings:settings)}
        result=try await engine.rememberRestoredSource(result,settings:settings)
        if let mid=result.manifestID {completed.remove(mid)}
        try await engine.settleManifest(result,settings:settings);return result
    }
}
