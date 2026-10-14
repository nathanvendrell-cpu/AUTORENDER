import Foundation

struct MacMonitorRegistryResult {
    var folders:[String:String]?
    var config:AppConfig?
    var added:[String]=[]
    var issue:String?
}

actor MacMonitorRegistryWorker {
    private struct Job:Decodable { let id:String?;let dossier:String }
    private let io=RenderBoundedIO()
    private let fileReader:(URL,RenderIOPermit) throws -> Data
    init(fileReader:@escaping (URL,RenderIOPermit) throws -> Data = { file,permit in
        try RenderRegularFile.read(file,maximumBytes:256*1024,permit:permit)
    }) { self.fileReader=fileReader }

    func reconcile(registry:URL,store:RenderConfigStore,writable:Bool) async -> MacMonitorRegistryResult {
        let reader=fileReader
        do {
            return try await io.run(lifetime:store.lifetime) { permit in
                try permit.check()
                let bytes=try reader(registry,permit)
                try permit.check()
                guard bytes.count<=256*1024 else { throw POSIXError(.EFBIG) }
                let jobs=try JSONDecoder().decode([Job].self,from:bytes)
                guard jobs.count<=256 else { throw POSIXError(.EFBIG) }
                let counts=Dictionary(jobs.compactMap(\.id).filter {!$0.isEmpty}.map {($0,1)},uniquingKeysWith:+)
                var folders:[String:String]=[:]
                for job in jobs {
                    try permit.check()
                    guard let id=job.id,counts[id]==1,(job.dossier as NSString).isAbsolutePath else { continue }
                    let folder=AppConfig.normalizedMacFolder(job.dossier)
                    var directory:ObjCBool=false
                    guard FileManager.default.fileExists(atPath:folder,isDirectory:&directory),directory.boolValue,
                          FileManager.default.isReadableFile(atPath:folder),FileManager.default.isExecutableFile(atPath:folder) else { continue }
                    folders[id]=folder
                }
                try permit.check()
                var result=MacMonitorRegistryResult(folders:folders)
                if writable {
                    var added:[String]=[]
                    result.config=try store.update(permit:permit) { added=$0.importNewMacMonitorFolders(Array(Set(folders.values)).sorted()) }
                    result.added=added
                }
                try permit.check()
                return result
            }
        } catch {
            return MacMonitorRegistryResult(issue:"Registre Mac indisponible, annulé ou délai IO atteint · associations conservées")
        }
    }
}
