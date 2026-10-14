import Foundation
import ImageIO
import CryptoKit
import Darwin

enum RenduStorage {
    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("RenduBar", isDirectory: true)
    }

    static func ensure() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("Previews"), withIntermediateDirectories: true)
    }

    static func load<T: Decodable>(_ name: String, as: T.Type) -> T? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, name: String) {
        ensure()
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: root.appendingPathComponent(name), options: .atomic)
    }
}

enum RenderConfigurationLoad {
    case missing
    case loaded(AppConfig)
    case unavailable(String)
    static func read(_ file:URL) -> Self {
        do { return decode(try RenderRegularFile.read(file,maximumBytes:8*1024*1024,allowSymlink:false)) }
        catch let error as POSIXError where error.code == .ENOENT { return .missing }
        catch { return .unavailable("Configuration existante illisible ou incompatible · fichier préservé") }
    }
    static func decode(_ data:Data) -> Self {
        do {
            guard let object=try JSONSerialization.jsonObject(with:data) as? [String:Any] else { return .unavailable("Configuration existante invalide · fichier préservé") }
            if let version=object["schemaVersion"] {
                guard let version=version as? Int,version<=1 else { return .unavailable("Configuration future/invalide · fichier préservé") }
            }
            return .loaded(try JSONDecoder().decode(AppConfig.self,from:data))
        } catch { return .unavailable("Configuration existante illisible ou incompatible · fichier préservé") }
    }
}


struct RenderConfigStore {
    let root:URL
    let lifetime:RenderTaskLifetime?
    init(root:URL,lifetime:RenderTaskLifetime?=nil) { self.root=root;self.lifetime=lifetime }
    private func checkpoint(_ permit:RenderIOPermit?) throws {
        try Task.checkCancellation();try lifetime?.check();try permit?.check()
    }
    func snapshot(permit:RenderIOPermit?=nil) throws -> AppConfig {
        try checkpoint(permit)
        let file=root.appendingPathComponent("config.json")
        let data:Data
        do { data=try RenderRegularFile.read(file,maximumBytes:8*1024*1024,permit:permit,allowSymlink:false) }
        catch let error as POSIXError where error.code == .ENOENT { return AppConfig() }
        try checkpoint(permit)
        switch RenderConfigurationLoad.decode(data) {
        case .loaded(let config):return config
        case .unavailable(let message):throw NSError(domain:"Configuration",code:3,userInfo:[NSLocalizedDescriptionKey:message])
        case .missing:return AppConfig()
        }
    }
    // Preserve unknown nested keys even when a sibling in the same typed dictionary is changed.
    private static func merge(original:Any?,old:Any?,new:Any) -> Any {
        if let old,NSDictionary(dictionary:["value":old]).isEqual(to:["value":new]) { return original ?? new }
        guard let before=old as? [String:Any],let after=new as? [String:Any],var stored=original as? [String:Any] else { return new }
        for key in before.keys where after[key]==nil { stored.removeValue(forKey:key) }
        for (key,value) in after { stored[key]=merge(original:stored[key],old:before[key],new:value) }
        return stored
    }
    func update(permit:RenderIOPermit?=nil,_ body:(inout AppConfig) throws -> Void) throws -> AppConfig {
        try checkpoint(permit)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try checkpoint(permit)
        let lockPath=root.appendingPathComponent("config.lock").path
        let descriptor=open(lockPath,O_CREAT|O_RDWR|O_NONBLOCK|O_CLOEXEC|O_NOFOLLOW,0o600)
        guard descriptor>=0 else { throw NSError(domain:"ConfigurationLock",code:1,userInfo:[NSLocalizedDescriptionKey:"Verrou configuration indisponible"]) }
        defer { close(descriptor) }
        var info=stat()
        guard fstat(descriptor,&info)==0,(info.st_mode & S_IFMT)==S_IFREG else { throw POSIXError(.EINVAL) }
        while flock(descriptor,LOCK_EX|LOCK_NB) != 0 {
            let failure=errno
            guard permit != nil, failure==EWOULDBLOCK || failure==EAGAIN || failure==EINTR else {
                throw NSError(domain:"ConfigurationLock",code:2,userInfo:[NSLocalizedDescriptionKey:"Configuration utilisée ailleurs · réessayer"])
            }
            try checkpoint(permit)
            usleep(1_000) // Existing bounded IO worker only; never wait on the main actor.
        }
        defer { flock(descriptor,LOCK_UN) }
        try checkpoint(permit)
        let target=root.appendingPathComponent("config.json")
        var document:[String:Any]=[:];var config=AppConfig();var before:Data?
        do { before=try RenderRegularFile.read(target,maximumBytes:8*1024*1024,permit:permit,allowSymlink:false) }
        catch let error as POSIXError where error.code == .ENOENT { }
        try checkpoint(permit)
        if let before {
            switch RenderConfigurationLoad.decode(before) {
            case .loaded(let loaded):config=loaded;document=try JSONSerialization.jsonObject(with:before) as? [String:Any] ?? [:]
            case .unavailable(let message):throw NSError(domain:"Configuration",code:3,userInfo:[NSLocalizedDescriptionKey:message])
            case .missing:break
            }
        }
        let encodedBefore=try JSONSerialization.jsonObject(with:JSONEncoder().encode(config)) as? [String:Any] ?? [:]
        try checkpoint(permit);try body(&config);try checkpoint(permit)
        let encoded=try JSONSerialization.jsonObject(with:JSONEncoder().encode(config)) as? [String:Any] ?? [:]
        for (key,value) in encoded {
            if before != nil,let old=encodedBefore[key],NSDictionary(dictionary:["value":old]).isEqual(to:["value":value]) { continue }
            if key=="jobArchives" && config.archivePayloadError != nil { continue }
            document[key]=Self.merge(original:document[key],old:before==nil ? nil : encodedBefore[key],new:value)
        }
        try checkpoint(permit)
        if let before,let original=try JSONSerialization.jsonObject(with:before) as? [String:Any],
           NSDictionary(dictionary:document).isEqual(to:original) { return config }
        let data=try JSONSerialization.data(withJSONObject:document,options:[.prettyPrinted,.sortedKeys])
        try checkpoint(permit)
        if data==before { return config }
        // Stage all data privately; no backup publication or target rename before the final guard.
        let temporary=root.appendingPathComponent("config.transaction-"+UUID().uuidString+".tmp")
        let pendingBackup=root.appendingPathComponent("config.backup-pending-"+UUID().uuidString+".tmp")
        defer { try? FileManager.default.removeItem(at:temporary);try? FileManager.default.removeItem(at:pendingBackup) }
        try checkpoint(permit);try data.write(to:temporary,options:.withoutOverwriting)
        try checkpoint(permit);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:temporary.path)
        if let before {
            try checkpoint(permit);try before.write(to:pendingBackup,options:.withoutOverwriting)
            try checkpoint(permit);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:pendingBackup.path)
        }
        try checkpoint(permit)
        if before != nil {
            let backup=root.appendingPathComponent("config.before-preference-change-"+UUID().uuidString+".json")
            try checkpoint(permit)
            guard rename(pendingBackup.path,backup.path)==0 else { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
        }
        try checkpoint(permit)
        guard rename(temporary.path,target.path)==0 else { throw NSError(domain:"Configuration",code:4,userInfo:[NSLocalizedDescriptionKey:"Écriture configuration impossible"]) }
        return config
    }
}
