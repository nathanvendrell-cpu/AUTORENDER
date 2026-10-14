import Foundation
import Darwin

final class NativeRefreshBarrier: @unchecked Sendable {
    let entered=DispatchSemaphore(value:0)
    let release=DispatchSemaphore(value:0)
    private let lock=NSLock();private var calls=0
    func holdFirstCompletion() {
        lock.lock();calls += 1;let first=calls==1;lock.unlock()
        if first { entered.signal();_ = release.wait(timeout:.now()+5) }
    }
    func signalled() -> Bool { entered.wait(timeout:.now()) == .success }
}
final class NativeRefreshReader:NativeProcessReading,@unchecked Sendable {
    let entered=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0)
    private let lock=NSLock();private var value=NativeProcessRead();private var calls=0
    func set(_ snapshot:NativeProcessSnapshot) { lock.lock();value=NativeProcessRead(snapshots:[snapshot]);lock.unlock() }
    func read() -> NativeProcessRead {
        lock.lock();calls += 1;let first=calls==1;let captured=value;lock.unlock()
        if first { entered.signal();_ = release.wait(timeout:.now()+5) }
        return captured
    }
    func signalled() -> Bool { entered.wait(timeout:.now()) == .success }
    var count:Int { lock.lock();defer {lock.unlock()};return calls }
}
@main enum NativeRefreshGenerationTests {
    static var checks=0
    static func check(_ condition:Bool,_ message:String) throws {checks += 1;if !condition {throw NSError(domain:message,code:1)}}
    @MainActor static func until(_ condition:() -> Bool) async throws {
        let deadline=DispatchTime.now().uptimeNanoseconds+2_000_000_000
        while !condition() { if DispatchTime.now().uptimeNanoseconds>=deadline {throw NSError(domain:"barrier deadline",code:1)};try await Task.sleep(for:.milliseconds(1)) }
    }
    @MainActor static func main() async throws {
        let fm=FileManager.default;let root=URL(fileURLWithPath:"/private/tmp").appendingPathComponent("autoren-generation-"+UUID().uuidString)
        try fm.createDirectory(at:root,withIntermediateDirectories:true);defer {try? fm.removeItem(at:root)}
        let a=root.appendingPathComponent("A"),b=root.appendingPathComponent("B")
        try fm.createDirectory(at:a,withIntermediateDirectories:true);try fm.createDirectory(at:b,withIntermediateDirectories:true)
        let reader=NativeRefreshReader(),barrier=NativeRefreshBarrier()
        let io=RenderBoundedIO(completionObserver:{barrier.holdFirstCompletion()})
        let model=MonitorModel(storageRoot:root,collectionEnabled:true,nativeReader:reader,nativeIO:io)
        let identity=NativeProcessIdentity(pid:901,birthSeconds:UInt64(Date().timeIntervalSince1970)-60,birthMicroseconds:1,executable:"/Applications/Blender.app/Contents/MacOS/Blender")
        let scene=root.appendingPathComponent("scene.blend").path
        func snapshot(_ output:URL) -> NativeProcessSnapshot {NativeProcessSnapshot(identity:identity,arguments:[identity.executable,"-b",scene,"-o",output.path+"/frame_####.png","-f","1"])}
        var failure:Error?;var reproduced=false
        do {
            try await until {reader.signalled()}
            #if BASELINE
            reader.set(snapshot(a));model.refreshLocalDiscovery()
            reader.set(snapshot(b));model.refreshLocalDiscovery()
            #else
            let initial=model.nativeRequestedGeneration
            reader.set(snapshot(a));let first=model.refreshLocalDiscovery()
            reader.set(snapshot(b));let second=model.refreshLocalDiscovery()
            try check(first==initial+1 && second==first+1,"two requests have no distinct monotonic tickets")
            #endif
            reader.release.signal();try await until {barrier.signalled()}
            #if BASELINE
            try await until {model.nativeHealth.message.contains("IO indisponible")}
            reproduced=io.isOccupied && !model.config.macFolders.contains(AppConfig.normalizedMacFolder(b.path))
            try check(reproduced,"expected baseline same-model lost refresh not reproduced")
            print("BEFORE REPRODUCED: completion notified while occupied=true; coalesced follow-up rejected; same model instance misses new CLI output root")
            #else
            try check(model.nativeRequestedGeneration==second,"pending refresh tickets changed or dropped")
            try await until {model.nativeCompletedGeneration>=initial}
            try check(model.nativeCatalogueGeneration<second,"earlier collection falsely acknowledges latest request")
            barrier.release.signal()
            let adopted=await model.waitForNativeDiscovery(second)
            try check(adopted && model.nativeCompletedGeneration>=second && model.nativeCatalogueGeneration>=second,"latest coalesced request never adopted")
            try check(model.config.macFolders.contains(AppConfig.normalizedMacFolder(b.path)),"same model instance misses new CLI output root")
            try check(!model.config.macFolders.contains(AppConfig.normalizedMacFolder(a.path)),"superseded unobserved root imported")
            try check(model.catalogSnapshot.jobs.contains {$0.id==identity.jobID},"ticket acknowledged before candidate catalogue adoption")
            try check(reader.count==4,"two pending requests did not coalesce to exactly one follow-up collection")
            try check(!model.nativeHealth.partial,"normal coalesced generation fails IO/transaction")
            try check(model.macHealth.checkedAt==nil && model.shadowHealth.checkedAt==nil,"refresh contacts provider")
            #endif
        } catch {failure=error}
        // Every test-owned barrier is released even if its expectation fails; join the model's work.
        reader.release.signal();barrier.release.signal();model.stop();await model.waitForShutdown()
        #if !BASELINE
        let stopped=await model.waitForNativeDiscovery(model.nativeRequestedGeneration)
        if failure==nil {try check(!stopped,"stopped lifetime reports further adoption")}
        #endif
        if let failure {throw failure}
        #if BASELINE
        guard reproduced else {throw NSError(domain:"baseline reproduction missing",code:1)}
        exit(42) // Expected preserved negative; all barriers/tasks already released/joined.
        #else
        print("NativeRefreshGenerationTests: \(checks) assertions PASS; two requests while in flight, release-before-notify, latest catalogue ticket, fixture cleanup")
        #endif
    }
}
