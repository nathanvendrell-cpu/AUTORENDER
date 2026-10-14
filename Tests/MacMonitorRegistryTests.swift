import Foundation

@main enum MacMonitorRegistryTests {
    static var checks = 0
    static func check(_ condition: Bool, _ message: String) { checks += 1; precondition(condition, message) }
    static func write(_ object: Any, _ url: URL) throws {
        try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]).write(to:url,options:.atomic)
    }
    static func backups(_ root: URL) throws -> Int {
        try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).filter { $0.lastPathComponent.hasPrefix("config.before-preference-change-") }.count
    }
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("autoren-registry-tests-"+UUID().uuidString)
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? fm.removeItem(at:root) }
        let storeRoot = root.appendingPathComponent("preferences")
        try fm.createDirectory(at:storeRoot,withIntermediateDirectories:true)
        let configFile = storeRoot.appendingPathComponent("config.json")
        let store = RenderConfigStore(root:storeRoot)
        let a = root.appendingPathComponent("A"); let b = root.appendingPathComponent("B")
        let denied = root.appendingPathComponent("denied")
        for folder in [a,b,denied] { try fm.createDirectory(at:folder,withIntermediateDirectories:true) }
        let unknown: [String:Any] = ["schemaVersion":1,"macFolders":[],"extensionObject":["future":true],
                                    "jobArchives":["future:job":"future-archive"], "folderWorkTypes":["future-path":"future-kind"]]
        try write(unknown,configFile)
        let initial = try Data(contentsOf:configFile)
        let one = root.appendingPathComponent("one.json"); let two = root.appendingPathComponent("two.json")
        let registry = root.appendingPathComponent("registry.json")
        try write([],one)
        try fm.createSymbolicLink(at:registry,withDestinationURL:one)
        let worker = MacMonitorRegistryWorker()
        var result = await worker.reconcile(registry:registry,store:store,writable:true)
        check(result.folders == [:] && result.added.isEmpty,"empty registry incorrect")
        check(try Data(contentsOf:configFile) == initial && backups(storeRoot) == 0,"unchanged cycle changes bytes/backups")
        try write([["id":"arrived","dossier":a.path]],one)
        result = await worker.reconcile(registry:registry,store:store,writable:true)
        check(result.added == [a.path] && result.config?.macFolders == [a.path],"same worker misses new job root")
        let afterArrival = try Data(contentsOf:configFile)
        let doc = try JSONSerialization.jsonObject(with:afterArrival) as! [String:Any]
        check((doc["extensionObject"] as? [String:Bool])?["future"] == true,"unknown top field lost")
        check((doc["folderWorkTypes"] as? [String:String])?["future-path"] == "future-kind","unknown nested field lost")
        check((doc["jobArchives"] as? [String:String])?["future:job"] == "future-archive","future archive overwritten")
        check(try backups(storeRoot) == 1,"arrival should have one recoverable backup")
        result = await worker.reconcile(registry:registry,store:store,writable:true)
        check(result.added.isEmpty && result.issue == nil,"repeated discovery not coalesced")
        check(try Data(contentsOf:configFile) == afterArrival && backups(storeRoot) == 1,"repeat creates backup/write")
        // Retarget the registry link; there is no application restart and no mtime assumption.
        try write([["id":"arrived","dossier":b.path]],two)
        try fm.removeItem(at:registry); try fm.createSymbolicLink(at:registry,withDestinationURL:two)
        result = await worker.reconcile(registry:registry,store:store,writable:true)
        check(result.folders?["arrived"] == b.path && result.added == [b.path],"registry symlink retarget missed")
        check(result.config?.macFolders.contains(a.path) == true,"retarget destructively removes old output root")
        _ = try store.update { $0.removeMacFolder(b.path) }
        result = await worker.reconcile(registry:registry,store:store,writable:true)
        check(result.added.isEmpty && result.config?.macFolders.contains(b.path) == false,"dismissed root resurrected")
        check(result.config?.dismissedMacFolders.contains(b.path) == true,"dismissal lost")
        try write([["id":"dup","dossier":a.path],["id":"dup","dossier":b.path],
                   ["id":"missing","dossier":root.appendingPathComponent("missing").path],
                   ["id":"relative","dossier":"relative/path"]],two)
        result = await worker.reconcile(registry:registry,store:store,writable:true)
        check(result.folders?.isEmpty == true,"duplicate ID/invalid root gets association")
        try write([],two)
        result = await worker.reconcile(registry:registry,store:store,writable:true)
        check(result.folders == [:] && result.config?.macFolders == [a.path],"registry removal deletes user root")
        try fm.setAttributes([.posixPermissions:0o000],ofItemAtPath:denied.path)
        defer { try? fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:denied.path) }
        try write([["id":"denied","dossier":denied.path]],two)
        result = await worker.reconcile(registry:registry,store:store,writable:true)
        check(result.folders == [:] && result.added.isEmpty,"inaccessible output root imported")
        try Data("{invalid".utf8).write(to:two)
        result = await worker.reconcile(registry:registry,store:store,writable:true)
        check(result.folders == nil && result.issue != nil,"invalid registry silently clears associations")
        try Data(repeating:65,count:256*1024+1).write(to:two)
        result = await worker.reconcile(registry:registry,store:store,writable:true)
        check(result.folders == nil && result.issue != nil,"oversized registry read unbounded")
        try write((0..<257).map { ["id":"job-\($0)","dossier":a.path] },two)
        result = await worker.reconcile(registry:registry,store:store,writable:true)
        check(result.folders == nil && result.issue != nil,"job count unbounded")
        try write([["id":"ok","dossier":a.path]],two)
        for bytes in [Data(#"{"schemaVersion":99,"macFolders":[]}"#.utf8),Data("unreadable JSON".utf8),Data(#"{"macFolders":17}"#.utf8)] {
            try bytes.write(to:configFile)
            let previousCount = try backups(storeRoot)
            result = await worker.reconcile(registry:registry,store:store,writable:true)
            check(result.config == nil && result.issue != nil,"future/invalid config accepted")
            check(try Data(contentsOf:configFile) == bytes && backups(storeRoot) == previousCount,"future/invalid config overwritten")
        }
        // File permission denial must preserve exact config bytes.
        try initial.write(to:configFile)
        try fm.setAttributes([.posixPermissions:0o000],ofItemAtPath:configFile.path)
        result = await worker.reconcile(registry:registry,store:store,writable:true)
        try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:configFile.path)
        check(try Data(contentsOf:configFile) == initial && result.config == nil && result.issue != nil,"unreadable config mutated")
        result = await worker.reconcile(registry:registry,store:store,writable:false)
        check(result.folders?["ok"] == a.path && result.config == nil,"read-only mapping needs config write")
        check(try Data(contentsOf:configFile) == initial,"read-only discovery writes configuration")
        print("MacMonitorRegistryTests: \(checks) assertions PASS; isolated filesystem fixtures; no renderer/provider/UI")
    }
}
