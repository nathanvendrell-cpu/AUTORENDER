import Foundation
import Darwin

actor ManagedRenderLibrary {
    enum Failure:Error {case notApproved,unstable,notFinal,invalidContext,unsafeRoot,collision,changed,notUndoable}
    let lifetime:RenderTaskLifetime?
    private let checkpoint:(@Sendable (RenderLibraryPhase)throws->Void)?
    private var issued:[String:String]=[:]
    private var issuedOrder:[String]=[]
    private var cache:[RenderLibraryRecord]=[]
    init(lifetime:RenderTaskLifetime?=nil,checkpoint:(@Sendable (RenderLibraryPhase)throws->Void)?=nil){self.lifetime=lifetime;self.checkpoint=checkpoint}
    func check()throws {try Task.checkCancellation();try lifetime?.check()}
    func root(_ settings:RenderLibrarySettings)throws->URL {
        guard settings.rootPath.hasPrefix("/") else{throw Failure.unsafeRoot}
        let root=URL(fileURLWithPath:RenderContextPath.absolute(settings.rootPath) ?? settings.rootPath)
        guard !root.pathComponents.contains(where:{$0.caseInsensitiveCompare("BRAIN") == .orderedSame}) else{throw Failure.unsafeRoot};return root
    }
    func store(_ root:URL,create:Bool)throws->RenderLibraryStore? {
        if !create && !RenderLibraryFilesystem.exists(root.appendingPathComponent(".autoren-library.sqlite3")){return nil}
        return try RenderLibraryStore(root:root,create:create)
    }
    private static func seal(_ plan:RenderLibraryPlan)->String {let e=JSONEncoder();e.outputFormatting=[.sortedKeys];return RenderContextPath.digest(String(data:(try? e.encode(plan)) ?? Data(),encoding:.utf8) ?? "")}
    func recentRecords(limit:Int=100)->[RenderLibraryRecord] {Array(cache.prefix(max(0,min(limit,200))))}
    private func location(_ job:RenderDashboardJob,_ c:RenderLibraryCandidate,_ root:URL,_ db:RenderLibraryStore?,reserve:Bool)throws->URL {
        var folder=root,parent="root"
        func name(_ kind:String,_ id:String,_ title:String)throws->String {
            let value=try db?.scopeName(kind:kind,parent:parent,identity:id,label:title,reserve:reserve) ?? RenderLibraryStore.readableName(title)
            parent=RenderContextPath.digest(parent+"|"+kind+"|"+id);return value
        }
        folder.appendPathComponent(try name("project",job.projectID,job.projectTitle!))
        if let id=job.subprojectID {folder.appendPathComponent(try name("subproject",id,job.subprojectTitle ?? "À classer"))}
        folder.appendPathComponent(try name("scene",job.sceneID!,job.sceneTitle!))
        folder.appendPathComponent(try name("version",job.libraryVersion!,job.libraryVersion!))
        folder.appendPathComponent(RenderLibraryStore.readableName(c.type))
        let take=try name("take",job.id+"|"+c.id,c.take)
        return folder.appendingPathComponent(take+"."+c.localFile.pathExtension.lowercased())
    }
    private static let types:Set<String>=["png","jpg","jpeg","webp","exr","tif","tiff","mp4","mov","mkv","wav","flac","mp3","aif","aiff"]
    private var plannedJobs:[String:RenderDashboardJob]=[:]
    func preview(job:RenderDashboardJob,candidate c:RenderLibraryCandidate,settings:RenderLibrarySettings)->RenderLibraryPlan {
        let fingerprint=c.expectedSHA256 ?? "\(c.secondStamp.device)|\(c.secondStamp.inode)|\(c.secondStamp.bytes)|\(c.secondStamp.modifiedSeconds)|\(c.secondStamp.modifiedNanoseconds)"
        let id=RenderContextPath.digest(fingerprint+"|"+c.id+"|"+job.id+"|"+job.projectID+"|"+(job.sceneID ?? "")+"|"+(job.libraryVersion ?? "")+"|"+settings.rootPath+"|"+(settings.activatedAt.map{String($0.timeIntervalSince1970)} ?? "none"))
        func plan(_ state:RenderLibraryState,_ reason:String,_ target:URL?=nil)->RenderLibraryPlan {
            let p=RenderLibraryPlan(id:id,candidate:c,target:target,state:state,reason:reason,activationAt:settings.activatedAt)
            issued[id]=Self.seal(p);plannedJobs[id]=job
            issuedOrder.removeAll{$0==id};issuedOrder.append(id)
            while issuedOrder.count>256 {let old=issuedOrder.removeFirst();issued.removeValue(forKey:old);plannedJobs.removeValue(forKey:old)}
            return p
        }
        if job.outputAvailability == .inMemory {return plan(.inMemory,"Render Result en mémoire · aucun fichier importable")}
        guard c.jobID==job.id,job.isTerminalRender,c.finalStageAttested else{return plan(.previewOnly,"Sortie finale non attestée")}
        guard c.firstStamp==c.secondStamp,c.firstStamp.bytes>0,c.secondObservedAt.timeIntervalSince(c.firstObservedAt)>=8 else{return plan(.previewOnly,"Deux observations stables espacées de 8 s requises")}
        guard Self.types.contains(c.localFile.pathExtension.lowercased()) else{return plan(.previewOnly,"Sources et réglages exclus")}
        guard job.contextAssignment == .assigned,job.hasVerifiedProjectContext==true,job.projectTitle != nil,job.sceneID != nil,job.sceneTitle != nil,job.libraryVersion != nil else{return plan(.needsClassification,"À classer · liaison projet/scène/version requise ; sous-projet optionnel")}
        do {
            let root=try self.root(settings),db=try store(root,create:false)
            let target=try location(job,c,root,db,reserve:false)
            guard settings.mode == .managedLibrary,let active=settings.activatedAt,let started=job.renderStartedAt,started==c.runStartedAt,started>=active else{return plan(.previewOnly,"Ancien média ou mode non activé · aperçu seulement",target)}
            return plan(.ready,"Nouveau job finalisé · plan exact",target)
        } catch {return plan(.conflict,"Bibliothèque ou métadonnées non sûres")}
    }
    func validate(_ r:RenderLibraryRecord,_ db:RenderLibraryStore)throws->URL {
        guard r.libraryID==db.libraryID,r.libraryRoot==db.root.path,let target=r.plan.target,target.path.hasPrefix(db.root.path+"/"),RenderContextPath.absolute(target.path)==target.path else{throw Failure.unsafeRoot}
        try RenderLibraryStore.directories(target.deletingLastPathComponent(),create:false)
        if let temp=r.tempPath {guard temp.deletingLastPathComponent()==target.deletingLastPathComponent(),temp.lastPathComponent==".autoren-"+r.id+".partial" else{throw Failure.unsafeRoot}}
        if let held=r.returnPath {guard held.deletingLastPathComponent()==r.plan.candidate.localFile.deletingLastPathComponent(),held.lastPathComponent==".autoren-return-"+r.id else{throw Failure.unsafeRoot}}
        return target
    }
    func verified(_ file:URL,_ r:RenderLibraryRecord)throws->Bool {
        guard RenderLibraryFilesystem.exists(file) else{return false}
        return try RenderLibraryFilesystem.hash(file,lifetime:lifetime)==r.sha256
    }
    func remember(_ r:RenderLibraryRecord){cache.removeAll{$0.id==r.id};cache.insert(r,at:0);if cache.count>200{cache.removeLast(cache.count-200)}}
    private func finish(_ original:RenderLibraryRecord,_ db:RenderLibraryStore)throws->RenderLibraryRecord {
        var r=original;let target=try validate(r,db),source=r.plan.candidate.localFile
        try check()
        guard r.phase != .remotePrepared,r.phase != .remoteUndoPrepared,r.phase != .remoteRestored else{throw Failure.notUndoable}
        if r.phase == .complete {
            guard try RenderLibraryFileStamp.read(target)==r.targetStamp,try verified(target,r) else{throw Failure.changed}
            if let held=r.returnPath,RenderLibraryFilesystem.exists(held) {
                guard try RenderLibraryFileStamp.read(held)==r.plan.candidate.secondStamp,try verified(held,r) else{throw Failure.changed}
                try RenderLibraryFilesystem.removeOwned(held,stamp:r.plan.candidate.secondStamp);r.returnPath=nil;try db.save(r)
            }
            remember(r);return r
        }
        if r.phase == .prepared {
            guard let temp=r.tempPath else{throw Failure.unsafeRoot}
            if RenderLibraryFilesystem.exists(temp){let fp=try RenderLibraryFileStamp.read(temp);try RenderLibraryFilesystem.removeOwned(temp,stamp:fp)}
            r.sha256=try RenderLibraryFilesystem.copy(source,temp,expected:r.plan.candidate.secondStamp,lifetime:lifetime)
            if let expected=r.plan.candidate.expectedSHA256,expected != r.sha256 {throw Failure.changed}
            r.tempStamp=try RenderLibraryFileStamp.read(temp)
            r.phase = .staged;try db.save(r);try checkpoint?(.staged)
        }
        if r.phase == .staged {
            guard let temp=r.tempPath,try RenderLibraryFileStamp.read(temp)==r.tempStamp,try verified(temp,r) else{throw Failure.changed}
            if RenderLibraryFilesystem.exists(target) {
                let a=try RenderLibraryFileStamp.read(temp),b=try RenderLibraryFileStamp.read(target)
                guard a.device==b.device,a.inode==b.inode,try verified(target,r) else{throw Failure.collision}
            } else {guard link(temp.path,target.path)==0 else{throw errno==EEXIST ? Failure.collision:Failure.changed}}
            try RenderLibraryFilesystem.syncDirectory(target.deletingLastPathComponent())
            guard try verified(target,r) else{throw Failure.changed}
            r.targetStamp=try RenderLibraryFileStamp.read(target)
            r.phase = .linked;try db.save(r);try checkpoint?(.linked)
        }
        if r.phase == .linked {
            guard try verified(target,r) else{throw Failure.changed}
            if r.moveApproved==true,r.plan.candidate.originalRemotePath==nil,let held=r.returnPath {
                if RenderLibraryFilesystem.exists(held) {
                    guard !RenderLibraryFilesystem.exists(source),try RenderLibraryFileStamp.read(held)==r.plan.candidate.secondStamp,try verified(held,r) else{throw Failure.changed}
                    r.phase = .sourceHeld;try db.save(r);try checkpoint?(.sourceHeld)
                } else if (try? RenderLibraryFileStamp.read(source))==r.plan.candidate.secondStamp {
                    try check();try RenderLibraryFilesystem.renameExclusive(source,held)
                    guard try RenderLibraryFileStamp.read(held)==r.plan.candidate.secondStamp else{throw Failure.changed}
                    r.phase = .sourceHeld;try db.save(r);try checkpoint?(.sourceHeld)
                } else {r.moveApproved=false;r.detail="Copie vérifiée · source évoluée ou absente, aucun retrait"}
            }
        }
        if r.phase == .sourceHeld {
            guard let held=r.returnPath,try RenderLibraryFileStamp.read(held)==r.plan.candidate.secondStamp,try verified(held,r),try verified(target,r) else{throw Failure.changed}
            try RenderLibraryFilesystem.syncDirectory(target.deletingLastPathComponent())
            r.state = .moved;r.phase = .complete;r.detail="Déplacement local vérifié et durable";try db.save(r)
            try RenderLibraryFilesystem.removeOwned(held,stamp:r.plan.candidate.secondStamp);r.returnPath=nil
        } else {r.state = .copiedSourceKept;r.phase = .complete;r.returnPath=nil;r.detail="Copie classée vérifiée · source conservée"}
        if let temp=r.tempPath,RenderLibraryFilesystem.exists(temp){let fp=try RenderLibraryFileStamp.read(temp);try RenderLibraryFilesystem.removeOwned(temp,stamp:fp)}
        r.tempPath=nil;try db.save(r);remember(r);return r
    }
    func execute(_ plan:RenderLibraryPlan,approval:RenderLibraryApproval,settings:RenderLibrarySettings)throws->RenderLibraryRecord {
        try check()
        guard approval.planIDs.contains(plan.id),settings.mode == .managedLibrary,plan.activationAt==settings.activatedAt else{throw Failure.notApproved}
        let root=try self.root(settings);guard let db=try store(root,create:true) else{throw Failure.unsafeRoot}
        if let prior=try db.find(planID:plan.id){guard prior.phase != .undone else{throw Failure.notApproved};return try finish(prior,db)}
        guard issued[plan.id]==Self.seal(plan),let job=plannedJobs[plan.id],plan.state == .ready || (approval.allowLegacy && plan.state == .previewOnly),let target=plan.target else{throw Failure.notApproved}
        guard try location(job,plan.candidate,root,db,reserve:true)==target else{throw Failure.notApproved}
        guard !RenderLibraryFilesystem.exists(target) else{throw Failure.collision}
        try RenderLibraryStore.directories(target.deletingLastPathComponent(),create:true)
        let id=UUID().uuidString
        var r=RenderLibraryRecord(id:id,plan:plan,at:Date(),state:.ready,sha256:"",detail:"Préparé")
        var context=job;context.previewEntries=[];r.contextJob=context
        r.libraryID=db.libraryID;r.libraryRoot=root.path;r.phase = .prepared;r.moveApproved=approval.allowLocalMove && plan.candidate.originalRemotePath==nil
        r.tempPath=target.deletingLastPathComponent().appendingPathComponent(".autoren-"+id+".partial")
        if r.moveApproved==true {r.returnPath=plan.candidate.localFile.deletingLastPathComponent().appendingPathComponent(".autoren-return-"+id)}
        try db.save(r);return try finish(r,db)
    }
    func recordByID(_ id:String,settings:RenderLibrarySettings)throws->RenderLibraryRecord? {try check();return try store(root(settings),create:false)?.find(recordID:id)}
    func recordForJob(_ id:String,settings:RenderLibrarySettings)throws->RenderLibraryRecord? {try store(root(settings),create:false)?.findJob(id)}
    private func remoteRecord(_ id:String,_ settings:RenderLibrarySettings)throws->(RenderLibraryStore,RenderLibraryRecord) {
        try check();guard let db=try store(root(settings),create:true),let r=try db.find(recordID:id) else{throw Failure.notApproved}
        let target=try validate(r,db);guard try RenderLibraryFileStamp.read(target)==r.targetStamp,try verified(target,r) else{throw Failure.changed};return (db,r)
    }
    func prepareRemoteRetirement(_ id:String,artifact:RenderRemoteArtifact,settings:RenderLibrarySettings)throws->RenderLibraryRecord {
        let (db,original)=try remoteRecord(id,settings);var r=original
        guard (r.state == .copiedSourceKept && r.phase == .complete) || r.phase == .remotePrepared,
              RenderContextPath.key(r.plan.candidate.originalRemotePath ?? "")==RenderContextPath.key(artifact.path),
              let start=r.plan.candidate.runStartedAt,let activation=settings.activatedAt,start>=activation,
              RenderDate.parseOptional(artifact.startedAt)==start else{throw Failure.notApproved}
        if let prior=r.remoteArtifact {guard prior==artifact else{throw Failure.changed}}
        r.remoteArtifact=artifact;r.remoteTransactionID=r.remoteTransactionID ?? RenderContextPath.digest(db.libraryID+"|"+r.id+"|"+r.sha256)
        r.phase = .remotePrepared;r.state = .awaitingTransfer;r.detail="Copie durable · retrait PC réversible en attente";try db.save(r);remember(r);return r
    }
    private func validateRemote(_ r:RenderLibraryRecord,_ p:RenderRemoteReturn)throws {
        guard let a=r.remoteArtifact,let transaction=r.remoteTransactionID,p.transactionID==transaction,p.sha256==r.sha256,p.connectionScope==a.connectionScope,
              RenderContextPath.key(p.originalPath)==RenderContextPath.key(a.path) else{throw Failure.changed}
        let normalized=a.path.replacingOccurrences(of:"\\",with:"/") as NSString
        let expected=(normalized.deletingLastPathComponent as NSString).appendingPathComponent(".autoren-returns/"+transaction+"."+normalized.pathExtension.lowercased())
        guard RenderContextPath.key(p.returnPath)==RenderContextPath.key(expected) else{throw Failure.unsafeRoot}
    }
    func commitRemoteRetirement(_ id:String,proof:RenderRemoteReturn,settings:RenderLibrarySettings)throws->RenderLibraryRecord {
        let (db,original)=try remoteRecord(id,settings);var r=original
        guard r.phase == .remotePrepared else{throw Failure.notApproved};try validateRemote(r,proof)
        r.remoteReturn=proof;r.state = .moved;r.phase = .complete;r.detail="Classé et vérifié · source PC dans la zone de retour réversible";try db.save(r);remember(r);return r
    }
    func finishRestoredRemoteUndo(_ id:String,settings:RenderLibrarySettings)throws->RenderLibraryRecord {
        try check();guard let db=try store(root(settings),create:true),var r=try db.find(recordID:id),r.phase == .remoteRestored,let proof=r.remoteReturn else{throw Failure.notApproved}
        try validateRemote(r,proof);let target=try validate(r,db)
        if RenderLibraryFilesystem.exists(target) {guard try RenderLibraryFileStamp.read(target)==r.targetStamp,try verified(target,r) else{throw Failure.changed};try RenderLibraryFilesystem.removeOwned(target,stamp:r.targetStamp!)}
        r.state = .undone;r.phase = .undone;r.detail="Source PC restaurée et hash vérifié · copie Mac retirée";try db.save(r);remember(r);return r
    }
    func prepareRemoteUndo(_ id:String,approvedRecordID:String,settings:RenderLibrarySettings)throws->RenderLibraryRecord {
        guard id==approvedRecordID else{throw Failure.notApproved}
        let (db,original)=try remoteRecord(id,settings);var r=original
        if r.phase == .remoteRestored {return r}
        guard r.phase == .complete || r.phase == .remotePrepared || r.phase == .remoteUndoPrepared else{throw Failure.notUndoable}
        guard r.plan.candidate.originalRemotePath != nil else{return r}
        guard let a=r.remoteArtifact ?? r.contextJob?.remoteArtifact else{throw Failure.notUndoable}
        r.remoteArtifact=a;r.remoteTransactionID=r.remoteTransactionID ?? RenderContextPath.digest(db.libraryID+"|"+r.id+"|"+r.sha256)
        r.phase = .remoteUndoPrepared;r.detail="Retour PC à vérifier avant retrait de la copie Mac";try db.save(r);remember(r);return r
    }
    func completeRemoteUndo(_ id:String,proof:RenderRemoteReturn,settings:RenderLibrarySettings)throws->RenderLibraryRecord {
        let (db,original)=try remoteRecord(id,settings);var r=original
        guard r.phase == .remoteUndoPrepared else{throw Failure.notApproved};try validateRemote(r,proof)
        let target=try validate(r,db);r.remoteReturn=proof;r.phase = .remoteRestored;try db.save(r);try checkpoint?(.remoteRestored)
        try check();try RenderLibraryFilesystem.removeOwned(target,stamp:r.targetStamp!)
        r.state = .undone;r.phase = .undone;r.detail="Source PC restaurée et hash vérifié · copie Mac retirée";try db.save(r);remember(r);return r
    }
    func loadRecent(settings:RenderLibrarySettings,limit:Int=100)throws->[RenderLibraryRecord] {
        guard let db=try store(root(settings),create:false) else{return []};cache=try db.recent(limit:limit);return cache
    }
    func pendingRecovery(settings:RenderLibrarySettings,limit:Int=20)throws->[RenderLibraryRecord] {try store(root(settings),create:false)?.recent(limit:limit,pendingOnly:true) ?? []}
    func recover(_ id:String,approvedRecordID:String,settings:RenderLibrarySettings)throws->RenderLibraryRecord {
        guard id==approvedRecordID,let db=try store(root(settings),create:true),let r=try db.find(recordID:id) else{throw Failure.notApproved}
        if r.phase == .undoPrepared || r.phase == .undoRestored {return try undo(id,approvedRecordID:id,settings:settings)}
        return try finish(r,db)
    }
    func undo(_ id:String,approvedRecordID:String,settings:RenderLibrarySettings)throws->RenderLibraryRecord {
        try check();guard id==approvedRecordID,let db=try store(root(settings),create:true),var r=try db.find(recordID:id) else{throw Failure.notApproved}
        guard r.remoteArtifact==nil,r.plan.candidate.originalRemotePath==nil else{throw Failure.notUndoable}
        if r.phase == .undone {return r}
        guard r.phase == .complete || r.phase == .undoPrepared || r.phase == .undoRestored else{throw Failure.notUndoable}
        let target=try validate(r,db),source=r.plan.candidate.localFile
        try RenderLibraryStore.directories(source.deletingLastPathComponent(),create:false)
        if r.phase != .undoRestored || RenderLibraryFilesystem.exists(target) {
            guard try RenderLibraryFileStamp.read(target)==r.targetStamp,try verified(target,r) else{throw Failure.changed}
        }
        if r.phase == .complete {
            if r.state == .moved {guard !RenderLibraryFilesystem.exists(source) else{throw Failure.collision}}
            else {guard r.state == .copiedSourceKept,try verified(source,r) else{throw Failure.changed}}
            r.phase = .undoPrepared;try db.save(r);try checkpoint?(.undoPrepared)
        }
        if r.phase == .undoPrepared {
            if r.state == .moved && !RenderLibraryFilesystem.exists(source) {
                if let held=r.returnPath,RenderLibraryFilesystem.exists(held){guard try verified(held,r) else{throw Failure.changed};try RenderLibraryFilesystem.renameExclusive(held,source)}
                else {
                    let temp=source.deletingLastPathComponent().appendingPathComponent(".autoren-undo-"+r.id+".partial")
                    if !RenderLibraryFilesystem.exists(temp) {
                        let digest=try RenderLibraryFilesystem.copy(target,temp,expected:RenderLibraryFileStamp.read(target),lifetime:lifetime)
                        guard digest==r.sha256 else{throw Failure.changed}
                    } else {guard try verified(temp,r) else{throw Failure.changed}}
                    try RenderLibraryFilesystem.renameExclusive(temp,source)
                }
            }
            guard try verified(source,r) else{throw Failure.changed}
            r.phase = .undoRestored;try db.save(r);try checkpoint?(.undoRestored)
        }
        guard try verified(source,r) else{throw Failure.changed}
        if RenderLibraryFilesystem.exists(target){try RenderLibraryFilesystem.removeOwned(target,stamp:r.targetStamp!)}
        r.state = .undone;r.phase = .undone;r.tempPath=nil;r.returnPath=nil;r.detail="Retour arrière vérifié · aucun écrasement";try db.save(r);remember(r);return r
    }
}
