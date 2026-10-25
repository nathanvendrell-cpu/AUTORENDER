import Foundation

struct NativeRenderDiscoveryResult {
    var observations: [NativeRenderObservation]
    var health: SourceHealth
    var config: AppConfig?
    var historyObservations:[NativeRenderObservation]=[]
}

private final class NativeRenderDiscoveryEngine {
    private let reader: any NativeProcessReading
    private let receipts=NativeJobReceiptReader()
    private var receiptPrevious:[String:(Int,Date)]=[:]
    private let scripts:any NativeScriptContractReading
    private struct FinishScope {
        var observation:NativeRenderObservation
        let descriptor:NativeScriptDescriptor
        var sample:NativePlannedFrameMetadata.Sample?
        var readsAfterExit=0
    }
    private struct DirectFinish {var observation:NativeRenderObservation;let descriptor:NativeScriptDescriptor;var stamp:NativePlannedFrameMetadata.Fingerprint?;var reads=0}
    private var directFinish:[String:DirectFinish]=[:]
    private var finishScopes:[String:FinishScope]=[:]
    private var plannedPrevious:[String:NativePlannedFrameMetadata.Sample]=[:]
    private var previous: [String:(run:String,count:Int,at:Date)] = [:]
    init(reader: any NativeProcessReading = NativeProcessReader(),scripts:any NativeScriptContractReading = NativeScriptContractReader()) { self.reader=reader;self.scripts=scripts }

    func collect(store: RenderConfigStore, links: [String:[String]], writable: Bool, at: Date, permit:RenderIOPermit,historicalJobs:[RenderDashboardJob]) throws -> NativeRenderDiscoveryResult {
        try permit.check()
        receipts.beginCollection()
        let sample=reader.read()
        try permit.check()
        var seen=Set<String>()
        var observations=sample.snapshots.prefix(64).compactMap { NativeRenderCommandParser.parse($0,at:at) }.filter { seen.insert($0.id).inserted }
        var nextPrevious=previous
        var nextPlanned=plannedPrevious
        var mappingIssue=false
        let configured:AppConfig?
        do { configured=try store.snapshot(permit:permit) }
        catch { configured=nil;mappingIssue=true }
        let mappings=configured?.nativeMetadataSources ?? [:]
        if mappings.count>32 { mappingIssue=true }
        if mappings.values.contains(where:{ source in !observations.contains { $0.identity==source.processIdentity && $0.scene==source.scene } }) { mappingIssue=true }
        var receiptValues:[String:NativeJobReceiptReader.Value]=[:]
        var bindings=Array((configured?.nativeJobReceipts ?? []).prefix(64))
        if let found=try? receipts.backfill(historicalJobs.filter{job in !bindings.contains{$0.identity.jobID==job.id}},now:at,permit:permit) {
            for binding in found where !bindings.contains(where:{$0.identity==binding.identity}) {if bindings.count<64{bindings.append(binding)}}
        }
        let retainedBindings=Set(bindings.map{$0.identity})
        for observation in observations {
            guard let directory=observation.jobDirectory,let scene=observation.scene,let script=observation.script else{continue}
            if let value=try? receipts.read(directory:directory,identity:observation.identity,scene:scene,renderer:script,now:at,binding:bindings.first(where:{$0.identity==observation.identity}),permit:permit) {
                receiptValues[observation.id]=value
                bindings.removeAll{$0.identity==observation.identity}
                bindings.append(value.binding)
                bindings=Array(bindings.sorted{$0.identity.bornAt>$1.identity.bornAt}.prefix(64))
            }
        }
        var automatic:[NativeProcessIdentity:NativeScriptDescriptor]=[:]
        for observation in observations where observation.script != nil && observation.scene != nil && receiptValues[observation.id]==nil && !mappings.values.contains(where:{$0.processIdentity==observation.identity}) {
            guard let snapshot=sample.snapshots.first(where:{$0.identity==observation.identity}) else{continue}
            do {
                if let descriptor=try scripts.infer(snapshot,observation:observation,permit:permit) {automatic[observation.identity]=descriptor}
                else {nextPlanned.removeValue(forKey:observation.id)}
            } catch {try permit.check();mappingIssue=true;nextPlanned.removeValue(forKey:observation.id)}
        }
        for index in observations.indices {
            try permit.check()
            var observation=observations[index]
            if observation.renderCommand {
                observation.taskQualification = .nativeRenderCommand
            }
            // User interface can explicitly associate a candidate run with one local output root.
            if let roots=links[observation.id],roots.count==1,let raw=NativeRenderPaths.absolute(roots[0]),let root=NativeRenderPaths.root(raw) {
                if observation.outputRoot == nil { observation.outputRoot=root;observation.stage += " · dossier lié par l’utilisateur" }
            }
            var scopes:[URL]=[]
            if let root=observation.outputRoot { scopes.append(URL(fileURLWithPath:root)) }
            if let scene=observation.scene { scopes.append(URL(fileURLWithPath:scene).deletingLastPathComponent()) }
            // Two exact metadata filenames maximum; no root search or Python/scene execution.
            let metadata=scopes.prefix(2).compactMap { NativeRenderMetadata.read($0.appendingPathComponent(".autorender.json"),for:observation,now:at,permit:permit) }
            // Conflicting declarations are ignored rather than picking one arbitrarily.
            if let first=metadata.first,metadata.allSatisfy({$0.0.runID==first.0.runID && AppConfig.normalizedMacFolder($0.0.outputRoot)==AppConfig.normalizedMacFolder(first.0.outputRoot) && $0.0.completed==first.0.completed && $0.0.total==first.0.total && $0.1==first.1}) {
                first.0.apply(to:&observation,at:first.1)
                if let n=observation.completed,let old=previous[observation.id],old.run==first.0.runID,
                   n>old.count,first.1>old.at,at.timeIntervalSince(first.1)<=20 {
                    observation.metadataAdvanced=true;observation.stage="Progression locale observée · processus associé"
                }
                if let n=observation.completed { nextPrevious[observation.id]=(first.0.runID,n,first.1) }
            }
            if let scene=observation.scene,mappings.count<=32 {
                let matched=mappings.filter { $0.value.processIdentity==observation.identity && $0.value.scene==scene }
                if matched.count==1,let pair=matched.first {
                    let source=pair.value
                    let current=NativePlannedFrameMetadata.Binding(pid:observation.identity.pid,birthSeconds:observation.identity.birthSeconds,
                        birthMicroseconds:observation.identity.birthMicroseconds,executable:observation.identity.executable,scene:scene)
                    var mapping=NativePlannedFrameMetadata.Mapping(metadataPath:source.metadataPath,outputRoot:source.outputRoot,
                        binding:current,plannedKey:source.plannedKey,filenamePattern:source.filenamePattern)
                    mapping.completedKey=source.completedKey;mapping.frameKey=source.frameKey;mapping.secondsKey=source.secondsKey
                    mapping.totalKey=source.totalKey;mapping.maximumBytes=source.maximumBytes
                    // Exclusivity must be explicit and not contradicted by any other observed process/mapping/provider root.
                    let scopeRoot=AppConfig.normalizedMacFolder(source.outputRoot)
                    let otherProcess=observations.contains { $0.id != observation.id && $0.outputRoot==scopeRoot }
                    let otherMapping=mappings.values.contains { $0.processIdentity != observation.identity && AppConfig.normalizedMacFolder($0.outputRoot)==scopeRoot }
                    let providerRoots=configured?.dashboardJobFolders.filter { !$0.key.hasPrefix("mac:native:") }.values.flatMap {$0} ?? []
                    mapping.exclusiveOutputScope=source.exclusiveOutputScope && !otherProcess && !otherMapping && !providerRoots.map(AppConfig.normalizedMacFolder).contains(scopeRoot)
                    do {
                        let sample=try NativePlannedFrameMetadata.read(mapping:mapping,current:current,now:at,
                            previous:plannedPrevious[observation.id],check:{ try permit.check() })
                        try permit.check()
                        guard let validRoot=NativeRenderPaths.root(source.outputRoot) else { throw NativePlannedFrameMetadata.Failure.mapping }
                        observation.outputRoot=validRoot;observation.outputPattern=URL(fileURLWithPath:validRoot).appendingPathComponent(source.filenamePattern).path
                        observation.completed=sample.completed;observation.declaredTotal=sample.total;observation.stableOutputCountVerified=sample.completed != nil && mapping.exclusiveOutputScope
                        observation.metadataObservedAt=sample.metadataModified;observation.metadataAdvanced=sample.outputAdvanced
                        observation.runID=source.runID ?? pair.key;observation.projectID=source.projectID;observation.workID=source.workID
                        observation.versionID=source.versionID;observation.workType=source.workType
                        observation.progressProvenance="Plan explicite · fichiers stables vérifiés sur deux lectures"
                        observation.stage=sample.completed==nil ? "Plan lié au processus · stabilité en cours de vérification" : "Plan lié au processus · fichiers stables vérifiés"
                        if sample.outputAdvanced { observation.stage += " · sortie attendue en progression" }
                        nextPlanned[observation.id]=sample
                    } catch { try permit.check();mappingIssue=true;nextPlanned.removeValue(forKey:observation.id) }
                } else if matched.count>1 { mappingIssue=true;nextPlanned.removeValue(forKey:observation.id) }
            }
            if observation.runID == nil,let scene=observation.scene,let descriptor=automatic[observation.identity] {
                if descriptor.isDirectRender {
                    observation.taskQualification = .nativeProductionContract
                    observation.declaredTotal=descriptor.descriptor.mode=="still" ? 1:nil
                    observation.outputPattern=descriptor.descriptor.filenamePattern.isEmpty ? nil:descriptor.descriptor.filenamePattern
                    observation.outputRoot=NativeRenderPaths.root(descriptor.descriptor.outputRoot)
                    observation.workType=descriptor.descriptor.mode=="still" ? .image:.video
                    observation.runID=descriptor.versionID
                    observation.stage="Invocation de rendu directe dans le script · préparation ou calcul · processus corrélé"
                    observation.progressProvenance="AST : invocation au premier niveau · compteur non mesuré"
                    observations[index]=observation
                    continue
                }
                let source=descriptor.mapping
                let current=NativePlannedFrameMetadata.Binding(pid:observation.identity.pid,birthSeconds:observation.identity.birthSeconds,
                    birthMicroseconds:observation.identity.birthMicroseconds,executable:observation.identity.executable,scene:scene)
                var mapping=NativePlannedFrameMetadata.Mapping(metadataPath:source.metadataPath,outputRoot:source.outputRoot,binding:current,plannedKey:source.plannedKey,filenamePattern:source.filenamePattern)
                let root=AppConfig.normalizedMacFolder(source.outputRoot)
                let shared=automatic.values.filter{AppConfig.normalizedMacFolder($0.mapping.outputRoot)==root}.count>1
                    || observations.contains{$0.identity != observation.identity && $0.outputRoot.map(AppConfig.normalizedMacFolder)==root}
                    || mappings.values.contains{AppConfig.normalizedMacFolder($0.outputRoot)==root}
                    || (configured?.dashboardJobFolders.filter{!$0.key.hasPrefix("mac:native:")}.values.flatMap{$0}.contains{AppConfig.normalizedMacFolder($0)==root} ?? false)
                    || observations.contains{$0.identity != observation.identity && $0.script != nil && $0.outputRoot == nil && automatic[$0.identity] == nil}
                    || sample.partial || sample.issue != nil
                mapping.exclusiveOutputScope = !shared
                mapping.requirePNGEnvelope=true
                mapping.expectedVariant=descriptor.descriptor.variant;mapping.expectedMode=descriptor.descriptor.mode;mapping.expectedFrames=descriptor.descriptor.planned
                observation.outputRoot=source.outputRoot;observation.outputPattern=URL(fileURLWithPath:source.outputRoot).appendingPathComponent(source.filenamePattern).path
                observation.declaredTotal=descriptor.descriptor.planned.count
                observation.runID=descriptor.versionID;observation.versionID=descriptor.versionID;observation.workType = .video
                observation.automaticProjectTitle=descriptor.projectTitle;observation.automaticComponentTitle=descriptor.componentTitle;observation.automaticVersionLabel=descriptor.versionLabel
                observation.taskQualification = .nativeProductionContract
                observation.outputScopeIsExclusive = !shared
                observation.progressProvenance="Plan du contrat statique · compteur non encore mesuré"
                observation.stage=shared ? "Tâche de rendu qualifiée · compteur non attribué, périmètre partagé ou incomplet" : "Tâche de rendu qualifiée · compteur en attente de mesure"

                if let fingerprint=descriptor.descriptor.metadataFingerprint {
                    mapping.expectedMetadata=NativePlannedFrameMetadata.Fingerprint(device:fingerprint.device,inode:fingerprint.inode,bytes:fingerprint.bytes,modified:Date(timeIntervalSince1970:fingerprint.modified))
                }
                if shared {
                    observation.completed=nil;observation.metadataAdvanced=false;observation.stableOutputCountVerified=false
                    observation.progressProvenance="Plan du contrat statique · compteur ambigu non attribué"
                    nextPlanned.removeValue(forKey:observation.id);mappingIssue=true
                } else {
                do {
                    let value=try NativePlannedFrameMetadata.read(mapping:mapping,current:current,now:at,previous:plannedPrevious[observation.id],check:{try permit.check()})
                    guard value.planned==descriptor.descriptor.planned.sorted() else{throw NativePlannedFrameMetadata.Failure.metadata}
                    observation.outputRoot=source.outputRoot;observation.outputPattern=URL(fileURLWithPath:source.outputRoot).appendingPathComponent(source.filenamePattern).path
                    observation.completed=value.completed;observation.declaredTotal=value.total;observation.stableOutputCountVerified=value.completed != nil && !shared;observation.metadataObservedAt=value.metadataModified
                    observation.metadataAdvanced=value.outputAdvanced;observation.progressObservedAt=value.outputAdvanced ? value.files.values.map(\.modified).max() : nil;observation.runID=descriptor.versionID;observation.versionID=descriptor.versionID;observation.workType = .video
                    observation.automaticProjectTitle=descriptor.projectTitle;observation.automaticComponentTitle=descriptor.componentTitle;observation.automaticVersionLabel=descriptor.versionLabel
                    observation.progressProvenance="Contrat AST du producteur observé · plan vérifié · conteneurs PNG cohérents et stables sur deux observations"
                    observation.stage=value.completed==nil ? "Contrat producteur qualifié · stabilité des PNG en attente" : "Contrat producteur qualifié · PNG stables comptées"
                    if value.outputAdvanced {observation.stage += " · sortie attendue en progression"}
                    else {observation.stage += observation.taskQualification == nil ? " · activité actuelle non attestée" : " · tâche active entre sorties, progression récente non observée"}
                    nextPlanned[observation.id]=value
                } catch {try permit.check();mappingIssue=true;nextPlanned.removeValue(forKey:observation.id);observation.stage += " · compteur indisponible ou incomplet"}
                }
            }
            try permit.check()
            if let value=receiptValues[observation.id] {value.apply(to:&observation,previous:receiptPrevious[observation.id])}
            observations[index]=observation
        }
        // Recheck the bounded same-user identity after filesystem IO before exposing or importing a root.
        let fresh=reader.read()
        try permit.check()
        let freshProcesses=fresh.snapshots.prefix(64).compactMap { NativeRenderCommandParser.parse($0,at:at) }
        observations=try observations.filter { candidate in
            guard freshProcesses.contains(where:{$0.identity==candidate.identity && $0.scene==candidate.scene && $0.script==candidate.script}) else{return false}
            guard sample.snapshots.first(where:{$0.identity==candidate.identity})?.arguments == fresh.snapshots.first(where:{$0.identity==candidate.identity})?.arguments else{return false}
            if let descriptor=automatic[candidate.identity],let script=candidate.script {
                do{return try descriptor.matchesScript(script,permit:permit)}catch{try permit.check();mappingIssue=true;return false}
            }
            return true
        }
        if fresh.partial || fresh.issue != nil {
            for index in observations.indices {
                // A positive revalidated task survives incomplete global coverage; its counter cannot claim exclusivity.
                observations[index].metadataAdvanced=false;observations[index].progressObservedAt=nil
                if automatic[observations[index].identity] != nil {
                    observations[index].completed=nil;observations[index].stableOutputCountVerified=false;observations[index].outputScopeIsExclusive=false
                    nextPlanned.removeValue(forKey:observations[index].id)
                }
            }
        }
        bindings=bindings.filter{binding in retainedBindings.contains(binding.identity) || observations.contains{$0.identity==binding.identity}}
        // A qualified binding survives the producer process and app restart; no synthetic live task.
        var receiptHistory:[NativeRenderObservation]=[]
        if !sample.partial && sample.issue==nil && !fresh.partial && fresh.issue==nil {
            for binding in bindings where !observations.contains(where:{$0.identity==binding.identity}) {
                try permit.check()
                if let value=try? receipts.read(binding:binding,now:at,permit:permit) {
                    var history=NativeRenderObservation(identity:binding.identity,producer:"Blender",observedAt:at)
                    history.processPresent=false;value.apply(to:&history);receiptHistory.append(history)
                }
            }
        }
        var nextDirect=directFinish
        for observation in observations {
            if let descriptor=automatic[observation.identity],descriptor.isDirectRender {
                nextDirect[observation.id]=DirectFinish(observation:observation,descriptor:descriptor)
            }
        }
        if nextDirect.count>64 {nextDirect=Dictionary(uniqueKeysWithValues:nextDirect.sorted{$0.value.observation.observedAt>$1.value.observation.observedAt}.prefix(64).map{($0.key,$0.value)})}
        if !sample.partial && sample.issue==nil && !fresh.partial && fresh.issue==nil {
            for id in Array(nextDirect.keys) where !observations.contains(where:{$0.id==id}) {
                guard var scope=nextDirect[id] else{continue};try permit.check();scope.reads += 1
                var history=scope.observation;history.processPresent=false;history.taskQualification=nil;history.metadataAdvanced=false
                history.activityOverride = .resumeRequired;history.stage="Processus disparu · fin ou interruption non attestée"
                if let path=history.outputPattern,scope.descriptor.descriptor.mode=="still",
                   !observations.contains(where:{$0.outputPattern==path || ($0.script != nil && $0.outputRoot==nil)}),
                   (try? scope.descriptor.matchesScript(history.script ?? "",permit:permit))==true {
                    let fd=open(path,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC)
                    if fd>=0 {
                        defer{close(fd)};var info=stat()
                        if fstat(fd,&info)==0,(info.st_mode & S_IFMT)==S_IFREG,info.st_size>0,
                           NativePlannedFrameMetadata.pngEnvelope(fd:fd,bytes:info.st_size) != nil {
                            let stamp=NativePlannedFrameMetadata.Fingerprint(device:UInt64(info.st_dev),inode:UInt64(info.st_ino),bytes:info.st_size,modified:Date(timeIntervalSince1970:Double(info.st_mtimespec.tv_sec)+Double(info.st_mtimespec.tv_nsec)/1e9))
                            if stamp.modified>=history.identity.bornAt,scope.stamp==stamp {
                                history.completed=1;history.declaredTotal=1;history.stableOutputCountVerified=true
                                history.activityOverride = .countsReached
                                history.progressProvenance="Sortie PNG exacte, conteneur cohérent et stable sur deux lectures · processus absent · décodage pixels non attesté"
                                history.stage="Image attendue stable comptée · fin technique, qualité et export final non attestés"
                            }
                            scope.stamp=stamp
                        }
                    }
                }
                receiptHistory.append(history)
                if history.completed==1 || scope.reads>=2 {nextDirect.removeValue(forKey:id)} else{nextDirect[id]=scope}
            }
        }
        var nextFinish=finishScopes
        for observation in observations {
            guard let descriptor=automatic[observation.identity] else{continue}
            if !descriptor.isDirectRender && observation.taskQualification == .nativeProductionContract && observation.outputScopeIsExclusive {
                nextFinish[observation.id]=FinishScope(observation:observation,descriptor:descriptor,sample:nextPlanned[observation.id])
            } else {nextFinish.removeValue(forKey:observation.id)}
        }
        if nextFinish.count>64 {
            let keep=Set(nextFinish.values.sorted{$0.observation.observedAt>$1.observation.observedAt}.prefix(64).map{$0.observation.id})
            nextFinish=nextFinish.filter{keep.contains($0.key)}
        }
        var historyObservations:[NativeRenderObservation]=receiptHistory
        let present=Set(observations.map(\.id))
        // Existing collection only: settle the last scoped outputs after a positively validated process absence.
        if !sample.partial && sample.issue==nil && !fresh.partial && fresh.issue==nil {
            for id in Array(nextFinish.keys).sorted() where !present.contains(id) {
                try permit.check()
                guard var scope=nextFinish[id] else{continue}
                let root=scope.descriptor.mapping.outputRoot
                let occupied=observations.contains{$0.outputRoot==root || ($0.script != nil && $0.outputRoot==nil)}
                    || automatic.values.contains{$0.versionID==scope.descriptor.versionID}
                if occupied {nextFinish.removeValue(forKey:id);continue}
                scope.readsAfterExit+=1
                do {
                    guard try scope.descriptor.matchesScript(scope.observation.script ?? "",permit:permit) else{throw NativePlannedFrameMetadata.Failure.unstable}
                    let identity=scope.observation.identity
                    let binding=NativePlannedFrameMetadata.Binding(pid:identity.pid,birthSeconds:identity.birthSeconds,birthMicroseconds:identity.birthMicroseconds,executable:identity.executable,scene:scope.descriptor.mapping.scene)
                    var mapping=NativePlannedFrameMetadata.Mapping(metadataPath:scope.descriptor.mapping.metadataPath,outputRoot:root,binding:binding,plannedKey:"planned",filenamePattern:scope.descriptor.mapping.filenamePattern)
                    mapping.requirePNGEnvelope=true;mapping.exclusiveOutputScope=true
                    mapping.expectedVariant=scope.descriptor.descriptor.variant;mapping.expectedMode=scope.descriptor.descriptor.mode;mapping.expectedFrames=scope.descriptor.descriptor.planned
                    let value=try NativePlannedFrameMetadata.read(mapping:mapping,current:binding,now:at,previous:scope.sample,check:{try permit.check()})
                    var history=scope.observation
                    history.processPresent=false;history.taskQualification=nil;history.metadataAdvanced=false;history.progressObservedAt=nil
                    history.completed=value.completed;history.declaredTotal=value.total;history.metadataObservedAt=value.metadataModified
                    history.stableOutputCountVerified=value.completed != nil
                    history.progressProvenance="Dernier contrat qualifié · sorties stables vérifiées sur deux observations · processus absent"
                    history.stage=value.completed==value.total ? "Sorties prévues stables comptées · fin technique, export non attesté" : "Processus absent · vérification des dernières sorties"
                    historyObservations.append(history);scope.sample=value
                    if value.completed==value.total || scope.readsAfterExit>=2 {nextFinish.removeValue(forKey:id)}
                    else {nextFinish[id]=scope}
                } catch {
                    try permit.check();mappingIssue=true
                    if scope.readsAfterExit>=2 {nextFinish.removeValue(forKey:id)} else {nextFinish[id]=scope}
                }
            }
        }
        seen=Set(observations.map(\.id))
        nextPlanned=nextPlanned.filter { seen.contains($0.key) }
        nextPrevious=nextPrevious.filter { seen.contains($0.key) }
        func accept(_ result:NativeRenderDiscoveryResult) throws -> NativeRenderDiscoveryResult {
            try permit.check()
            plannedPrevious=nextPlanned;previous=nextPrevious;finishScopes=nextFinish;directFinish=nextDirect
            receiptPrevious=Dictionary(uniqueKeysWithValues:receiptValues.map{($0.key,($0.value.completed,$0.value.at))})
            return result
        }
        var health=SourceHealth();health.online=sample.issue==nil || !observations.isEmpty
        health.partial=sample.partial || sample.snapshots.count>64 || fresh.partial || fresh.issue != nil || mappingIssue;health.isStale=sample.snapshots.isEmpty && sample.issue != nil
        health.checkedAt=at;health.observedAt=at;health.lastGoodAt=health.online ? at : nil
        let qualified=observations.filter { $0.renderCommand || $0.runID != nil }.count
        health.message=sample.issue ?? "\(observations.count) processus candidat(s) · \(qualified) commande(s) ou métadonnée(s) qualifiée(s) · activité distincte"
        if mappingIssue { health.message += " · source de progression indisponible ou ambiguë" }
        var result=NativeRenderDiscoveryResult(observations:observations,health:health)
        result.historyObservations=historyObservations
        try permit.check()
        guard writable else { return try accept(result) }
        let roots=Array(Set(observations.compactMap(\.outputRoot))).sorted()
        guard !roots.isEmpty || bindings != (configured?.nativeJobReceipts ?? []) else { return try accept(result) }
        do { result.config=try store.update(permit:permit) { _=$0.importNewMacMonitorFolders(roots);$0.nativeJobReceipts=bindings.isEmpty ? nil:bindings } }
        catch { result.health.partial=true;result.health.message += " · préférences indisponibles" }
        try permit.check()
        return try accept(result)
    }
}


actor NativeRenderDiscovery {
    private let io:RenderBoundedIO
    private let engine:NativeRenderDiscoveryEngine
    init(reader:any NativeProcessReading = NativeProcessReader(),io:RenderBoundedIO=RenderBoundedIO(),scripts:any NativeScriptContractReading = NativeScriptContractReader()) { engine=NativeRenderDiscoveryEngine(reader:reader,scripts:scripts);self.io=io }
    func collect(store:RenderConfigStore,links:[String:[String]],writable:Bool,at:Date=Date(),historicalJobs:[RenderDashboardJob]=[]) async -> NativeRenderDiscoveryResult {
        let engine=self.engine
        do { return try await io.run(lifetime:store.lifetime) { permit in try engine.collect(store:store,links:links,writable:writable,at:at,permit:permit,historicalJobs:historicalJobs) } }
        catch {
            var health=SourceHealth();health.partial=true;health.isStale=true;health.checkedAt=at
            health.message="Découverte locale annulée, IO indisponible ou délai atteint · activité inconnue"
            return NativeRenderDiscoveryResult(observations:[],health:health)
        }
    }
}
