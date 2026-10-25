import Foundation

extension ManagedRenderLibrary {
    func manifestID(_ job:RenderDashboardJob)->String {RenderContextPath.digest(job.id+"|"+(job.libraryInvocationID ?? job.remoteArtifact?.invocationToken ?? job.id))}
    func recordForArtifact(jobID:String,artifactID:String,settings:RenderLibrarySettings)throws->RenderLibraryRecord? {try store(root(settings),create:false)?.findArtifact(jobID:jobID,artifactID:artifactID)}
    func manifestCheckpoint(_ id:String,settings:RenderLibrarySettings)throws->RenderLibraryManifestCheckpoint? {try store(root(settings),create:true)?.manifest(id)}
    func enqueueManifest(job:RenderDashboardJob,settings:RenderLibrarySettings)throws {
        try check();guard job.isTerminalRender,job.finalOutputProof != nil,job.outputAvailability == .fileAttested,let count=job.outputExpectedCount,count>0,count<=50_000,let start=job.renderStartedAt,let active=settings.activatedAt,start>=active else{return}
        guard let db=try store(root(settings),create:true) else{throw Failure.unsafeRoot};let id=manifestID(job)
        if try db.manifest(id) != nil {return}
        var context=job;context.previewEntries=[]
        var m=RenderLibraryManifestCheckpoint(id:id,jobID:job.id,invocationID:job.libraryInvocationID ?? job.remoteArtifact?.invocationToken ?? job.id,expectedCount:count,complete:true,listingComplete:false,nextCursor:0)
        m.contextJob=context;m.remote=job.remoteArtifact?.manifest;try db.saveManifest(m)
    }
    func pendingManifestJobs(settings:RenderLibrarySettings)throws->[RenderDashboardJob] {try store(root(settings),create:true)?.pendingManifests(limit:16).compactMap(\.contextJob) ?? []}
    func touchManifest(_ job:RenderDashboardJob,settings:RenderLibrarySettings)throws {guard let db=try store(root(settings),create:true),let m=try db.manifest(manifestID(job)) else{return};try db.saveManifest(m)}
    func prepareManifest(job:RenderDashboardJob,settings:RenderLibrarySettings)throws->RenderLibraryManifestCheckpoint {
        try check();let root=try self.root(settings);guard let db=try store(root,create:true) else{throw Failure.unsafeRoot}
        let id=manifestID(job);let prior=try db.manifest(id)
        if let prior {guard prior.jobID==job.id else{throw Failure.invalidContext};if prior.listingComplete || job.remoteArtifact != nil {return prior}}
        guard job.isTerminalRender,job.finalOutputProof != nil,let count=job.outputExpectedCount,count>0,count<=50_000,let started=job.renderStartedAt,let active=settings.activatedAt,started>=active else{throw Failure.notFinal}
        var manifest=prior ?? RenderLibraryManifestCheckpoint(id:id,jobID:job.id,invocationID:job.libraryInvocationID ?? job.remoteArtifact?.invocationToken ?? job.id,expectedCount:count,complete:true,listingComplete:false,nextCursor:0)
        var context=job;context.previewEntries=[];manifest.contextJob=context
        if let a=job.remoteArtifact {
            if let d=a.manifest {guard d.complete,d.expectedCount==count else{throw Failure.notFinal};manifest.remote=d}
            else if a.scriptProof==nil {guard count==1 else{throw Failure.notFinal}}
            try db.saveManifest(manifest);return manifest
        }
        guard let pattern=job.sourceContext?.outputPath,pattern.hasPrefix("/") else{throw Failure.invalidContext}
        let folder=URL(fileURLWithPath:pattern).deletingLastPathComponent();try RenderLibraryStore.directories(folder,create:false)
        guard let enumerator=FileManager.default.enumerator(at:folder,includingPropertiesForKeys:nil,options:[.skipsSubdirectoryDescendants,.skipsHiddenFiles]) else{throw Failure.notFinal}
        var paths:[String]=[]
        while let file=enumerator.nextObject() as? URL {
            try check();guard RenderArtifactPattern.matches(file.path,pattern:pattern) else{continue}
            guard paths.count<50_000,let stamp=try? RenderLibraryFileStamp.read(file),stamp.bytes>0,Double(stamp.modifiedSeconds)+Double(stamp.modifiedNanoseconds)/1e9>=started.timeIntervalSince1970 else{throw Failure.notFinal}
            paths.append(file.path)
        }
        guard paths.count==count else{throw Failure.notFinal};paths.sort()
        try db.saveManifest(manifest)
        var offset=0
        while offset<paths.count {
            let page=paths[offset..<min(paths.count,offset+64)].enumerated().map{n,path in RenderLibraryManifestItem(manifestID:id,position:offset+n,artifact:RenderLibraryArtifact(id:RenderContextPath.digest(id+"|"+path),path:path))}
            offset+=page.count;manifest.nextCursor=offset;manifest.listingComplete=offset==paths.count
            try check();try db.appendManifestPage(page,checkpoint:manifest)
        }
        return manifest
    }
    func appendRemoteManifest(_ page:RenderLibraryRemotePage,job:RenderDashboardJob,settings:RenderLibrarySettings)throws->RenderLibraryManifestCheckpoint {
        try check();let id=manifestID(job);guard let db=try store(root(settings),create:true),var m=try db.manifest(id),page.complete,page.descriptor.complete,page.descriptor.expectedCount==m.expectedCount,!page.artifacts.isEmpty,page.artifacts.count<=32 else{throw Failure.notFinal}
        if let existing=m.remote {guard existing==page.descriptor else{throw Failure.changed}}
        guard m.nextCursor+page.artifacts.count<=m.expectedCount,page.nextCursor==nil || page.nextCursor==m.nextCursor+page.artifacts.count else{throw Failure.changed}
        let items=page.artifacts.enumerated().map{n,a in RenderLibraryManifestItem(manifestID:id,position:m.nextCursor+n,artifact:a)}
        m.remote=page.descriptor;m.nextCursor+=items.count;m.listingComplete=page.nextCursor==nil && m.nextCursor==m.expectedCount
        try db.appendManifestPage(items,checkpoint:m);return m
    }
    func manifestPage(_ id:String,after:Int,settings:RenderLibrarySettings)throws->[RenderLibraryManifestItem] {try store(root(settings),create:true)?.manifestPage(id,after:after,limit:4) ?? []}
    func attachManifest(_ record:RenderLibraryRecord,manifestID:String,settings:RenderLibrarySettings)throws->RenderLibraryRecord {
        try check();guard let db=try store(root(settings),create:true),let m=try db.manifest(manifestID),m.jobID==record.plan.candidate.jobID,var r=try db.find(recordID:record.id) else{throw Failure.invalidContext}
        if let prior=r.manifestID {guard prior==manifestID else{throw Failure.changed}}
        r.manifestID=manifestID;try db.save(r);try db.settleManifest(r);remember(r);return r
    }
    func releaseStaging(_ record:RenderLibraryRecord,settings:RenderLibrarySettings)throws {
        guard record.phase == .complete,record.plan.candidate.originalRemotePath != nil,record.sha256==record.plan.candidate.expectedSHA256 else{return}
        let file=record.plan.candidate.localFile,staging=try root(settings).appendingPathComponent(".autoren-staging")
        guard file.deletingLastPathComponent()==staging,file.lastPathComponent==record.plan.candidate.id+"."+file.pathExtension else{throw Failure.unsafeRoot}
        if RenderLibraryFilesystem.exists(file){guard try RenderLibraryFileStamp.read(file)==record.plan.candidate.secondStamp,try verified(file,record) else{throw Failure.changed};try RenderLibraryFilesystem.removeOwned(file,stamp:record.plan.candidate.secondStamp)}
    }
    func settleManifest(_ r:RenderLibraryRecord,settings:RenderLibrarySettings)throws {guard let db=try store(root(settings),create:true) else{throw Failure.unsafeRoot};try db.settleManifest(r)}
    func advanceManifest(_ id:String,processed:Int,settings:RenderLibrarySettings)throws->RenderLibraryManifestCheckpoint {
        guard let db=try store(root(settings),create:true),var m=try db.manifest(id),processed>=m.processedCursor,processed<=m.nextCursor else{throw Failure.changed};m.processedCursor=processed;try db.saveManifest(m);return m
    }
    func wholeManifestMoved(_ id:String,settings:RenderLibrarySettings)throws->Bool {try store(root(settings),create:true)?.validateWholeManifest(id) ?? false}
    func rememberRestoredSource(_ original:RenderLibraryRecord,settings:RenderLibrarySettings)throws->RenderLibraryRecord {
        guard original.phase == .undone,original.plan.candidate.originalRemotePath==nil else{return original}
        try check();guard let db=try store(root(settings),create:true),var r=try db.find(recordID:original.id) else{throw Failure.notApproved}
        try RenderLibraryStore.directories(r.plan.candidate.localFile.deletingLastPathComponent(),create:false)
        r.restoredSourceStamp=try RenderLibraryFileStamp.read(r.plan.candidate.localFile);try db.save(r);remember(r);return r
    }
    func recordsForJob(_ id:String,cursor:String?,limit:Int,settings:RenderLibrarySettings)throws->RenderLibraryJobPage {
        guard let db=try store(root(settings),create:false) else{return .init(records:[],nextCursor:nil)}
        return try db.recordsForJob(id,cursor:cursor,limit:limit)
    }
    func verifiedLocation(_ id:String,settings:RenderLibrarySettings)throws->RenderLibraryLocation {
        try check();guard let db=try store(root(settings),create:false),let r=try db.find(recordID:id) else{throw Failure.notApproved}
        if r.phase == .complete,[RenderLibraryState.moved,.copiedSourceKept].contains(r.state) {
            let target=try validate(r,db);guard try RenderLibraryFileStamp.read(target)==r.targetStamp else{throw Failure.changed}
            return .init(fileURL:target,remoteDisplay:nil,classified:true)
        }
        if r.phase == .undone {
            if let path=r.remoteReturn?.originalPath {return .init(fileURL:nil,remoteDisplay:path,classified:false)}
            let source=r.plan.candidate.localFile;try RenderLibraryStore.directories(source.deletingLastPathComponent(),create:false)
            guard try RenderLibraryFileStamp.read(source)==(r.restoredSourceStamp ?? r.plan.candidate.secondStamp) else{throw Failure.changed};return .init(fileURL:source,remoteDisplay:nil,classified:false)
        }
        throw Failure.notFinal
    }

}
