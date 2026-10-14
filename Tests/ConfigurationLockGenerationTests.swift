import Foundation
import Darwin
@main enum ConfigurationLockGenerationTests {
    static var checks=0
    static func check(_ value:Bool,_ message:String) throws {checks+=1;if !value {throw NSError(domain:message,code:1)}}
    static func main() async throws {
        let root=URL(fileURLWithPath:"/private/tmp").appendingPathComponent("autoren-config-lock-"+UUID().uuidString)
        let fm=FileManager.default;try fm.createDirectory(at:root,withIntermediateDirectories:true);defer{try? fm.removeItem(at:root)}
        let store=RenderConfigStore(root:root);_=try store.update {_ in}
        let target=root.appendingPathComponent("config.json");let original=try Data(contentsOf:target)
        let fd=open(root.appendingPathComponent("config.lock").path,O_RDWR|O_CLOEXEC)
        guard fd>=0 else{throw POSIXError(.EIO)};defer{flock(fd,LOCK_UN);close(fd)}
        try check(flock(fd,LOCK_EX|LOCK_NB)==0,"fixture cannot own configuration lock")
        let io=RenderBoundedIO();var failure:Error?
        do {_ = try await io.run(seconds:0.1) {permit in try store.update(permit:permit) {$0.macFolders=[root.path+"/should-not-commit"]} }}
        catch {failure=error}
        #if BASELINE
        try check((failure as NSError?)?.domain=="ConfigurationLock","baseline contention did not reject immediately")
        print("BEFORE REPRODUCED: an otherwise valid bounded collector transaction is immediately rejected by another local collector lock")
        #else
        try check(failure is CancellationError || failure is RenderIOFailure,"lock contention does not respect bounded IO deadline")
        #endif
        flock(fd,LOCK_UN)
        let deadline=DispatchTime.now().uptimeNanoseconds+1_000_000_000
        while io.isOccupied {if DispatchTime.now().uptimeNanoseconds>=deadline {throw NSError(domain:"fixture IO not rejoined",code:1)};try await Task.sleep(for:.milliseconds(1))}
        try check(try Data(contentsOf:target)==original,"expired transaction writes configuration")
        let folder=root.appendingPathComponent("renders");try fm.createDirectory(at:folder,withIntermediateDirectories:true)
        let accepted=try await io.run {permit in try store.update(permit:permit) {$0.macFolders=[folder.path]} }
        try check(accepted.macFolders==[folder.path],"released lock not usable on next generation")
        // UI preference calls without a collector permit still fail immediately, never blocking the main actor.
        try check(flock(fd,LOCK_EX|LOCK_NB)==0,"fixture cannot reacquire lock")
        var synchronous:Error?
        do {_=try store.update {_ in}} catch {synchronous=error}
        try check((synchronous as NSError?)?.domain=="ConfigurationLock","unbounded UI call started waiting for lock")
        print("ConfigurationLockGenerationTests: \(checks) assertions PASS; bounded contention, expired zero-write, next transaction and immediate UI path")
    }
}
