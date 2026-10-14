import Foundation
import AppKit
import Darwin

actor NonCooperativePreview {
    private var continuation:CheckedContinuation<(NSImage,Data)?,Never>?
    private(set) var entered=false
    func read() async -> (NSImage,Data)? {
        entered=true
        return await withCheckedContinuation { continuation=$0 }
    }
    func release() { continuation?.resume(returning:(NSImage(size:NSSize(width:2,height:2)),Data([1])));continuation=nil }
}

@main enum BoundedDiscoveryShutdownTests {
    static var checks=0
    static func check(_ condition:Bool,_ message:String) { checks+=1;precondition(condition,message) }
    static func backupCount(_ root:URL) throws -> Int {
        try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).filter {$0.lastPathComponent.hasPrefix("config.before-preference-change-")}.count
    }
    static func wait(_ semaphore:DispatchSemaphore) async throws {
        for _ in 0..<1000 { if semaphore.wait(timeout:.now()) == .success { return };try await Task.sleep(for:.milliseconds(1)) }
        preconditionFailure("fixture IO failed to reach barrier")
    }
    @MainActor static func main() async throws {
        let fm=FileManager.default
        let root=fm.temporaryDirectory.appendingPathComponent("autoren-bounded-cancel-"+UUID().uuidString)
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? fm.removeItem(at:root) }
        let prefs=root.appendingPathComponent("prefs");let output=root.appendingPathComponent("output")
        for path in [prefs,output] { try fm.createDirectory(at:path,withIntermediateDirectories:true) }
        let configFile=prefs.appendingPathComponent("config.json")
        let initial=try JSONEncoder().encode(AppConfig());try initial.write(to:configFile)
        let payload=try JSONSerialization.data(withJSONObject:[["id":"test","dossier":output.path]])
        let began=DispatchSemaphore(value:0);let release=DispatchSemaphore(value:0);let finished=DispatchSemaphore(value:0)
        defer { release.signal() }
        let worker=MacMonitorRegistryWorker(fileReader:{ _,_ in
            began.signal();defer {finished.signal()};_ = release.wait(timeout:.now()+4);return payload
        })
        let task=Task { await worker.reconcile(registry:root.appendingPathComponent("unused"),store:RenderConfigStore(root:prefs),writable:true) }
        try await wait(began);let cancelledAt=Date();task.cancel()
        let result=await task.value
        check(Date().timeIntervalSince(cancelledAt)<0.3 && result.added.isEmpty,"caller waits on noncooperative cancelled IO")
        check(try Data(contentsOf:configFile)==initial && backupCount(prefs)==0,"cancelled IO persists before release")
        release.signal();try await wait(finished);try await Task.sleep(for:.milliseconds(20))
        check(try Data(contentsOf:configFile)==initial && backupCount(prefs)==0,"cancelled IO writes after release")
        // Prove a deadline and single-slot policy without cancelling the task.
        let began2=DispatchSemaphore(value:0);let release2=DispatchSemaphore(value:0);let finished2=DispatchSemaphore(value:0)
        defer { release2.signal() }
        let slow=MacMonitorRegistryWorker(fileReader:{ _,_ in began2.signal();defer {finished2.signal()};_ = release2.wait(timeout:.now()+4);return payload })
        let start=Date();let delayed=Task { await slow.reconcile(registry:root.appendingPathComponent("unused"),store:RenderConfigStore(root:prefs),writable:true) }
        try await wait(began2);let timedOut=await delayed.value
        check(Date().timeIntervalSince(start)<3 && timedOut.added.isEmpty,"regular-file OS stall suspends caller beyond deadline")
        let retryAt=Date();let busy=await slow.reconcile(registry:root.appendingPathComponent("unused"),store:RenderConfigStore(root:prefs),writable:true)
        check(Date().timeIntervalSince(retryAt)<0.2 && busy.issue != nil,"timeout launches unbounded additional worker")
        release2.signal();try await wait(finished2);try await Task.sleep(for:.milliseconds(20))
        check(try Data(contentsOf:configFile)==initial && backupCount(prefs)==0,"expired IO creates config/backup")
        // Invalidate while the preference body still owns its lock, before serialization/publication.
        let lifetime=RenderTaskLifetime();let permit=RenderIOPermit(seconds:1,lifetime:lifetime)
        let store=RenderConfigStore(root:prefs,lifetime:lifetime)
        do { _=try store.update(permit:permit) { $0.addMacFolder(output.path);lifetime.invalidate() };preconditionFailure("invalidated transaction commits") }
        catch { }
        check(try Data(contentsOf:configFile)==initial && backupCount(prefs)==0,"lifetime closed during transaction still publishes")
        // Future unknown sibling survives mutation of its same dictionary.
        let future:[String:Any]=["macFolders":[],"folderWorkTypes":["future":"future-kind","known":"image"]]
        try JSONSerialization.data(withJSONObject:future).write(to:configFile)
        _=try RenderConfigStore(root:prefs).update { $0.folderWorkTypes["known"] = .video }
        let merged=try JSONSerialization.jsonObject(with:Data(contentsOf:configFile)) as! [String:Any]
        check((merged["folderWorkTypes"] as? [String:String])?["future"]=="future-kind" && (merged["folderWorkTypes"] as? [String:String])?["known"]=="video","same-field mutation drops unknown future sibling")
        // Global model shutdown: an actual noncooperative preview continuation stays suspended.
        let gate=NonCooperativePreview();let modelRoot=root.appendingPathComponent("model")
        let model=MonitorModel(storageRoot:modelRoot,collectionEnabled:false,previewLoader:{_ in await gate.read()})
        let entry=RenderEntry(id:"fixture",source:.macFolder,job:"fixture",filename:"frame.png",modified:Date(),state:.stable,path:nil,previewURL:nil)
        model.setVisiblePreviewEntries([entry])
        for _ in 0..<200 { if await gate.entered {break};try await Task.sleep(for:.milliseconds(5)) }
        check(await gate.entered,"preview fixture did not enter asynchronous suspension")
        let stoppedAt=Date();model.stop();await model.waitForShutdown()
        check(Date().timeIntervalSince(stoppedAt)<3 && model.shutdownIssue != nil,"global shutdown waits forever on old preview collector")
        await gate.release();try await Task.sleep(for:.milliseconds(40))
        check(model.thumbnail(for:entry)==nil,"released old preview publishes after stop")
        let files=(fm.enumerator(at:modelRoot,includingPropertiesForKeys:nil)?.allObjects as? [URL]) ?? []
        check(!files.contains {$0.pathExtension=="jpg" || $0.pathExtension=="png"},"old preview writes cache after stop")
        await model.waitForShutdown()
        print("BoundedDiscoveryShutdownTests: \(checks) assertions PASS; cancelled/expired IO zero config writes, finite global shutdown, fixtures rejoined")
    }
}
