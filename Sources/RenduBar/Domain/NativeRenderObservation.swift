import Foundation
import CryptoKit

struct NativeProcessIdentity: Codable, Equatable, Hashable {
    let pid: Int32
    let birthSeconds: UInt64
    let birthMicroseconds: UInt64
    let executable: String
    var bornAt: Date { Date(timeIntervalSince1970:Double(birthSeconds)+Double(birthMicroseconds)/1_000_000) }
    var jobID: String {
        let value = "\(pid)|\(birthSeconds)|\(birthMicroseconds)|\(executable)"
        return "mac:native:" + SHA256.hash(data:Data(value.utf8)).map { String(format:"%02x",$0) }.joined()
    }
}

// argv is transient input only; never encoded, persisted, logged, or copied into a catalogue.
struct NativeProcessSnapshot {
    let identity: NativeProcessIdentity
    let arguments: [String]?
}

struct NativeRenderObservation {
    let identity: NativeProcessIdentity
    let producer: String
    var scene: String?
    var script: String?
    var outputRoot: String?
    var outputPattern: String?
    var renderCommand = false
    var declaredTotal: Int?
    var completed: Int?
    var metadataObservedAt: Date?
    var workType: RenderWorkType?
    var projectID: String?
    var workID: String?
    var versionID: String?
    var runID: String?
    var outputRole: String?
    var stage = "Processus candidat · activité non attribuée"
    var metadataAdvanced = false
    var taskQualification: RenderTaskQualification? = nil
    var progressObservedAt: Date? = nil
    var stableOutputCountVerified = false
    var outputScopeIsExclusive = false
    var processPresent = true
    var progressProvenance:String?=nil
    var automaticProjectTitle:String?=nil
    var automaticComponentTitle:String?=nil
    var automaticVersionLabel:String?=nil
    let observedAt: Date
    var id: String { identity.jobID }

    func matchesOutput(_ path: String) -> Bool {
        guard let pattern = outputPattern else { return false }
        if !pattern.contains("#"), !pattern.contains("%") { return path == pattern }
        // Only one numeric placeholder is accepted, not a general filesystem glob.
        let token: String
        if pattern.contains("#") {
            guard let first=pattern.firstIndex(of:"#") else { return false }
            let end=pattern[first...].firstIndex(where:{$0 != "#"}) ?? pattern.endIndex
            token=String(pattern[first..<end])
        } else {
            guard let regex=try? NSRegularExpression(pattern:#"%0?[0-9]*d"#),
                  let match=regex.firstMatch(in:pattern,range:NSRange(pattern.startIndex...,in:pattern)),
                  let range=Range(match.range,in:pattern) else { return false }
            token=String(pattern[range])
        }
        let parts=pattern.components(separatedBy:token)
        guard parts.count==2, !parts[0].contains("%"), !parts[1].contains("%"),
              !parts[0].contains("#"), !parts[1].contains("#"), path.hasPrefix(parts[0]), path.hasSuffix(parts[1]),
              path.count > parts[0].count+parts[1].count else { return false }
        let middle=path.dropFirst(parts[0].count).dropLast(parts[1].count)
        // Blender may add an extension to a prefix-only output argument. This is left unqualified.
        return middle.allSatisfy { $0.isASCII && $0.isNumber }
    }

    // Root previews provide context without asserting that this process produced every file.
    func previewScopeIncludes(_ path: String) -> Bool {
        if outputPattern != nil { return matchesOutput(path) }
        return outputRoot.map { RenderOrganization.isInside(path,root:$0) } ?? false
    }

    func dashboard(entries: [RenderEntry], sharedRoot: Bool = false, now: Date = Date()) -> RenderDashboardJob {
        let outputs=entries.filter { entry in
            guard let path=entry.path else { return false }
            return previewScopeIncludes(path)
        }.sorted { $0.modified > $1.modified }
        let outputAdvanced = !sharedRoot && renderCommand && outputPattern != nil && outputs.contains {
            $0.modified >= identity.bornAt && now.timeIntervalSince($0.modified) >= 0 && now.timeIntervalSince($0.modified) <= 20
        }
        let terminal=stableOutputCountVerified && completed != nil && completed==declaredTotal && (declaredTotal ?? 0)>0
        let activity: RenderActivity = terminal ? .countsReached : (taskQualification != nil || metadataAdvanced || outputAdvanced ? .running : .unknown)
        let progress=completed.flatMap { n in declaredTotal.flatMap { RenderProgress(completed:n,total:$0) } }
        let title=automaticComponentTitle ?? (producer + " · " + (scene.map { ($0 as NSString).lastPathComponent } ?? "processus candidat"))
        var job=RenderDashboardJob(id:id,title:title,projectID:projectID ?? "native:" + id,source:.macMonitor,
            workType:workType,rawCount:completed,postCount:nil,rawProgress:progress,postProgress:nil,
            totalProvenance:declaredTotal == nil ? nil : (progressProvenance ?? (metadataObservedAt == nil ? "Arguments CLI explicites" : "Métadonnées locales associées au processus")),
            activity:activity,isFresh:now.timeIntervalSince(observedAt)<=30,observedAt:observedAt,
            lastActivity:metadataAdvanced ? metadataObservedAt : outputs.first?.modified,historicalMedianSeconds:nil,
            sampledOutputsLastHour:nil,eta:nil,process:nil,gpu:nil,gpuRaw:nil,plans:[],tasks:[],
            stageDescription:outputAdvanced ? "Sortie récente · commande de rendu associée" : (sharedRoot && !metadataAdvanced ? stage + " · dossier partagé, activité non attribuée" : stage),previewEntries:Array(outputs.filter { $0.kind == .image }.prefix(2)))
        if let project=automaticProjectTitle {job.projectTitle=project};if let label=automaticVersionLabel {job.versionLabel=label}
        if !processPresent {job.isFresh=false;job.retainedHistorical=true}
        job.taskQualification=processPresent ? taskQualification : nil
        job.progressObservedAt=progressObservedAt ?? (outputAdvanced ? outputs.first?.modified : nil)
        job.workTitle=automaticComponentTitle
        job.workID=workID;job.versionID=versionID;job.sourceWorkID=workID;job.sourceVersionID=versionID
        job.contextProvenance = automaticComponentTitle != nil ? "Contrat statique du producteur · libellés issus des arguments · lien métier non déclaré" : runID == nil ? "Processus local observé · lien métier non déclaré" : "Métadonnées locales explicites"
        job.baseProjectID=job.projectID
        return job
    }
}

enum NativeRenderPaths {
    static func absolute(_ raw: String, scene: String? = nil) -> String? {
        guard !raw.isEmpty, raw.utf8.count<=4096, !raw.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) else { return nil }
        if raw.hasPrefix("//"), let scene {
            return URL(fileURLWithPath:scene).deletingLastPathComponent().appendingPathComponent(String(raw.dropFirst(2))).standardizedFileURL.path
        }
        guard (raw as NSString).isAbsolutePath, !raw.contains("://") else { return nil }
        return URL(fileURLWithPath:raw).standardizedFileURL.path
    }
    static func root(_ path: String) -> String? {
        let value=AppConfig.normalizedMacFolder(path)
        let denied=["/","/Users","/Volumes","/Applications","/Library","/System","/private","/private/tmp","/tmp",FileManager.default.homeDirectoryForCurrentUser.path]
        guard !denied.contains(value) else { return nil }
        var directory: ObjCBool=false
        guard FileManager.default.fileExists(atPath:value,isDirectory:&directory),directory.boolValue,
              FileManager.default.isReadableFile(atPath:value),FileManager.default.isExecutableFile(atPath:value) else { return nil }
        return value
    }
}
