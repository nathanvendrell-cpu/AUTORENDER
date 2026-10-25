import Foundation
import CryptoKit

enum RenderContextOrigin:String,Codable {case nativeBlender,commandLine,staticProducer,unknown}
struct RenderSourceContext:Codable,Equatable {
    var filePath:String?=nil
    var sceneName:String?=nil
    var scriptPath:String?=nil
    var outputPath:String?=nil
    var namespace:String?=nil
    var origin:RenderContextOrigin = .unknown
    private enum CodingKeys:String,CodingKey {case filePath,sceneName,scriptPath,outputPath,origin,namespace}
    init(filePath:String?=nil,sceneName:String?=nil,scriptPath:String?=nil,outputPath:String?=nil,namespace:String?=nil,origin:RenderContextOrigin) {
        self.filePath=filePath;self.sceneName=sceneName;self.scriptPath=scriptPath;self.outputPath=outputPath;self.namespace=namespace;self.origin=origin
    }
    // Context errors never invalidate an otherwise qualified render observation.
    init(from decoder:Decoder)throws {
        self.init(origin:.unknown)
        guard let c=try? decoder.container(keyedBy:CodingKeys.self) else{return}
        filePath=try? c.decode(String.self,forKey:.filePath);sceneName=try? c.decode(String.self,forKey:.sceneName)
        scriptPath=try? c.decode(String.self,forKey:.scriptPath);outputPath=try? c.decode(String.self,forKey:.outputPath)
        namespace=try? c.decode(String.self,forKey:.namespace)
        origin=(try? c.decode(RenderContextOrigin.self,forKey:.origin)) ?? .unknown
    }
    var sanitized:Self? {
        guard origin != .unknown else{return nil}
        var result=self
        result.filePath=filePath.flatMap(RenderContextPath.absolute)
        result.scriptPath=scriptPath.flatMap(RenderContextPath.absolute)
        result.outputPath=outputPath.flatMap(RenderContextPath.absolute)
        result.namespace=RenderContextPath.label(namespace)
        result.sceneName=RenderContextPath.label(sceneName)
        return result.filePath==nil && result.scriptPath==nil && result.outputPath==nil && result.sceneName==nil ? nil:result
    }
}
enum RenderContextPath {
    static func label(_ value:String?,limit:Int=256)->String? {
        guard let value,!value.isEmpty,value.utf8.count<=limit,!value.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) else{return nil}
        let clean=value.trimmingCharacters(in:.whitespacesAndNewlines);return clean.isEmpty ? nil:clean
    }
    static func absolute(_ value:String)->String? {
        guard !value.isEmpty,value.utf8.count<=4096,!value.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains),!value.contains("://") else{return nil}
        let slash=value.replacingOccurrences(of:"\\",with:"/")
        let windows=slash.range(of:"^[A-Za-z]:/",options:.regularExpression) != nil
        guard windows || (slash.hasPrefix("/") && !slash.hasPrefix("//")) else{return nil}
        var components:[String]=[]
        for component in slash.split(separator:"/").map(String.init) {
            if component=="." {continue}
            if component==".." {if !components.isEmpty && !(windows && components.count==1){components.removeLast()};continue}
            components.append(component)
        }
        return (windows ? "":"/")+components.joined(separator:"/")
    }
    static func key(_ value:String)->String? {absolute(value).map{$0.dropFirst().first==":" ? $0.lowercased():$0}}
    static func leaf(_ value:String)->String {value.replacingOccurrences(of:"\\",with:"/").split(separator:"/").last.map(String.init) ?? value}
    static func digest(_ value:String)->String {SHA256.hash(data:Data(value.utf8)).map{String(format:"%02x",$0)}.joined()}
}

struct RenderProjectRoot:Codable,Equatable {let path:String;let namespace:String}
struct RenderProjectBinding:Codable,Equatable,Identifiable {
    let id:String
    var title:String
    var roots:[RenderProjectRoot]
    var isValid:Bool {RenderContextPath.label(id) != nil && RenderContextPath.label(title) != nil && !roots.isEmpty && roots.count<=32 && roots.allSatisfy{RenderContextPath.absolute($0.path) != nil && RenderContextPath.label($0.namespace) != nil}}
}
struct RenderContextRule:Codable,Equatable,Identifiable {
    let id:String;let rootPath:String
    var namespace:String?=nil
    var exactFileName:String?=nil
    var nativeSceneName:String?=nil
    let context:RenderJobContext
    var canonicalFileBase:String?=nil
    var subprojectPathLevel:Int?=nil
    var isValid:Bool {RenderContextPath.label(id,limit:80) != nil && RenderContextPath.absolute(rootPath) != nil && subprojectPathLevel.map{(0...16).contains($0)} != false}
    func matches(_ source:RenderSourceContext?)->Bool {
        guard isValid,let source,let root=RenderContextPath.key(rootPath) else{return false}
        if let namespace {guard source.namespace==namespace else{return false}}
        else {guard source.namespace==nil || source.namespace=="mac-local" else{return false}}
        let paths=[source.filePath,source.scriptPath,source.outputPath].compactMap{$0}.compactMap(RenderContextPath.key)
        guard paths.contains(where:{$0==root || $0.hasPrefix(root+"/")}) else{return false}
        if let exactFileName,source.filePath.map(RenderContextPath.leaf) != exactFileName{return false}
        if let canonicalFileBase,source.filePath.map({RenderVersionToken.parse(RenderContextPath.leaf($0)).base}) != canonicalFileBase{return false}
        if let nativeSceneName,source.sceneName != nativeSceneName{return false}
        return true
    }
}
enum RenderContextAssignment:String,Codable {case assigned,ambiguous,unknown}
enum RenderVersionToken {
    private static let tokenRegex=try! NSRegularExpression(pattern:"(?i)(?<![\\p{L}\\p{N}])v([0-9]{1,6})(?![\\p{L}\\p{N}])")
    struct Result {let base:String;let version:String?;let ambiguous:Bool}
    static func version(_ value:String?)->String? {
        guard let value,let regex=try? NSRegularExpression(pattern:"^[vV]([0-9]{1,6})$"),let match=regex.firstMatch(in:value,range:NSRange(value.startIndex...,in:value)),let range=Range(match.range(at:1),in:value),let n=Int(value[range]) else{return nil}
        return "v"+String(format:"%03d",n)
    }
    static func parse(_ filename:String)->Result {
        let stem=(filename as NSString).deletingPathExtension
        let regex=tokenRegex
        let matches=regex.matches(in:stem,range:NSRange(stem.startIndex...,in:stem))
        let versions=Set(matches.compactMap{Range($0.range,in:stem).flatMap{version(String(stem[$0]))}})
        guard versions.count<=1 else{return Result(base:stem,version:nil,ambiguous:true)}
        var base=stem
        for match in matches.reversed(){if let r=Range(match.range,in:base){base.removeSubrange(r)}}
        base=base.trimmingCharacters(in:CharacterSet(charactersIn:" _.-"))
        return Result(base:base,version:versions.first,ambiguous:false)
    }
}

// Pure catalogue classification. No disk scan, guessed client or mutation of media.
struct RenderContextResolver {
    private let config:AppConfig
    init(config:AppConfig){self.config=config}
    func apply(_ original:RenderDashboardJob)->RenderDashboardJob {
        var job=original
        let source=job.sourceContext?.sanitized;job.sourceContext=source
        let namespace=source?.namespace ?? (job.source.isShadow ? "shadow-unscoped":"mac-local")
        let paths=[source?.filePath,source?.outputPath,source?.scriptPath].compactMap{$0}.compactMap(RenderContextPath.key)
        // A saved explicit binding can retain an offline catalogue label, without granting file authority.
        if paths.isEmpty,config.jobContexts[job.id]==nil,let saved=job.baseProjectID,
           let binding=(config.projectBindings ?? []).first(where:{$0.id==saved && $0.isValid && $0.roots.contains{$0.namespace==namespace}}) {
            job.projectID=binding.id;job.projectTitle=binding.title;job.contextAssignment = .assigned
            job.hasVerifiedProjectContext=false
            job.contextProvenance="Identité de catalogue conservée · binding exact et namespace compatible · source hors ligne, déplacement non autorisé"
            return job
        }
        let matchingRules=(config.contextRules ?? []).filter{$0.matches(source)}
        let contexts=matchingRules.map(\.context)
        let ruleConflict=contexts.dropFirst().contains{$0 != contexts.first}
        let direct=config.jobContexts[job.id]
        let chosen=direct ?? (ruleConflict ? nil:contexts.first)
        var matches:[(id:String,title:String,root:String)]=[]
        for binding in config.projectBindings ?? [] where binding.isValid {
            for root in binding.roots where root.namespace==namespace {
                if let key=RenderContextPath.key(root.path),paths.contains(where:{$0==key || $0.hasPrefix(key+"/")}) {matches.append((binding.id,binding.title,key))}
            }
        }
        let explicitMatches=matches
        // Legacy configured roots remain reusable, but equal labels do not merge distinct roots/hosts.
        for (root,title) in config.folderProjects {
            guard let key=RenderContextPath.key(root),RenderContextPath.label(title) != nil,paths.contains(where:{$0==key || $0.hasPrefix(key+"/")}) else{continue}
            let legacyPaths=paths.filter{$0==key || $0.hasPrefix(key+"/")}
            if !explicitMatches.isEmpty && legacyPaths.allSatisfy({path in explicitMatches.contains{path==$0.root || path.hasPrefix($0.root+"/")}}){continue}
            let id="folder-binding:"+RenderContextPath.digest(namespace+"|"+key)
            if !matches.contains(where:{$0.root==key}) {matches.append((id,title,key))}
        }
        let ids=Set(matches.map(\.id));var evidence:[String]=[];var anchor:String?
        if let id=RenderContextPath.label(chosen?.projectID) {
            job.projectID=id;job.projectTitle=RenderContextPath.label(chosen?.projectTitle) ?? job.projectTitle ?? "À classer"
            job.contextAssignment = .assigned;anchor=matches.first(where:{$0.id==id})?.root
            evidence.append(direct==nil ? "Projet : règle explicite "+matchingRules.map(\.id).joined(separator:","):"Projet : liaison explicite")
        } else if !ruleConflict,ids.count==1,let match=matches.sorted(by:{$0.root.count>$1.root.count}).first {
            job.projectID=match.id;job.projectTitle=match.title;job.contextAssignment = .assigned;anchor=match.root
            evidence.append("Projet : racine liée et namespace source")
        } else {
            job.projectID="unclassified:"+namespace;job.projectTitle="À classer"
            job.contextAssignment = (ids.count>1 || ruleConflict) ? .ambiguous:.unknown
            evidence.append(job.contextAssignment == .ambiguous ? "Projet : liaisons contradictoires":"Projet : preuve de liaison absente")
        }
        job.hasVerifiedProjectContext=job.contextAssignment == .assigned
        let asset=source?.filePath ?? source?.scriptPath ?? source?.outputPath
        let token=RenderVersionToken.parse(asset.map(RenderContextPath.leaf) ?? job.title)
        job.subprojectID=RenderContextPath.label(chosen?.subprojectID);job.subprojectTitle=RenderContextPath.label(chosen?.subprojectTitle)
        if job.subprojectID==nil,let rule=matchingRules.first,let level=rule.subprojectPathLevel,let asset,let root=RenderContextPath.key(rule.rootPath),let key=RenderContextPath.key(asset),key.hasPrefix(root+"/") {
            let folders=key.dropFirst(root.count+1).split(separator:"/").dropLast().filter{RenderVersionToken.version(String($0))==nil}.map(String.init)
            if folders.indices.contains(level) {job.subprojectTitle=folders[level];job.subprojectID="subproject:"+RenderContextPath.digest(job.projectID+"|"+folders.prefix(level+1).joined(separator:"/"));evidence.append("Sous-projet : niveau de structure explicitement lié")}
        }
        if let id=RenderContextPath.label(chosen?.sceneID) {job.sceneID=id;job.sceneTitle=RenderContextPath.label(chosen?.sceneTitle) ?? source?.sceneName;evidence.append("Scène : liaison explicite")}
        else if let asset,job.hasVerifiedProjectContext==true {
            let key=RenderContextPath.key(asset) ?? asset
            let relative=anchor.flatMap{key.hasPrefix($0+"/") ? String(key.dropFirst($0.count+1)):nil} ?? key
            let parent=relative.split(separator:"/").dropLast().map(String.init).filter{RenderVersionToken.version($0)==nil}.joined(separator:"/")
            let identity=[job.projectID,job.subprojectID ?? "",parent,token.base,source?.sceneName ?? ""].joined(separator:"\u{1f}")
            job.sceneID="scene:"+RenderContextPath.digest(identity)
            job.sceneTitle=source?.sceneName.map{token.base.isEmpty || $0==token.base ? $0:token.base+" · "+$0} ?? (token.base.isEmpty ? "Scène":token.base)
            evidence.append(source?.sceneName==nil ? "Scène logique : base du fichier source, scène interne non fournie":"Scène : fichier version-indépendant et nom natif")
        } else {job.sceneID=nil;job.sceneTitle=nil}
        if let label=chosen?.workTitle {job.workTitle=RenderContextPath.label(label)}
        else if job.sourceWorkID==nil && job.sourceVersionID==nil {job.workTitle=nil}
        if chosen?.versionLabel==nil && job.sourceVersionID==nil {job.versionLabel=asset.map(RenderContextPath.leaf) ?? source?.sceneName ?? job.versionLabel ?? job.title}
        job.libraryVersion=RenderVersionToken.version(chosen?.libraryVersion) ?? RenderVersionToken.version(chosen?.versionLabel) ?? RenderVersionToken.version(job.versionLabel) ?? token.version
        if token.ambiguous && chosen?.libraryVersion==nil {job.libraryVersion=nil;evidence.append("Version : jetons contradictoires")}
        else if let version=job.libraryVersion {evidence.append("Version : jeton explicite "+version)}
        if let source {evidence.append("Source : "+source.origin.rawValue)}
        job.contextProvenance=evidence.joined(separator:" · ")
        return job
    }
}
