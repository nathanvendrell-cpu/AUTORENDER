import Foundation
import Darwin

final class PausedNativeReader:NativeProcessReading {
    let began=DispatchSemaphore(value:0);let release=DispatchSemaphore(value:0);let finished=DispatchSemaphore(value:0)
    let sample:NativeProcessSnapshot
    init(_ sample:NativeProcessSnapshot) { self.sample=sample }
    func read() -> NativeProcessRead {
        began.signal();defer { finished.signal() };_ = release.wait(timeout:.now()+4)
        return NativeProcessRead(snapshots:[sample])
    }
}
@main enum NativeCancellationPrivacyTests {
    static var checks=0
    static func check(_ condition:Bool,_ message:String) { checks+=1;precondition(condition,message) }
    static func wait(_ semaphore:DispatchSemaphore) async throws {
        for _ in 0..<1000 { if semaphore.wait(timeout:.now()) == .success { return };try await Task.sleep(for:.milliseconds(1)) }
        preconditionFailure("fixture did not finish within bound")
    }
    static func main() async throws {
        let fm=FileManager.default
        let root=fm.temporaryDirectory.appendingPathComponent("autoren-native-cancel-"+UUID().uuidString)
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? fm.removeItem(at:root) }
        let prefs=root.appendingPathComponent("prefs");let output=root.appendingPathComponent("output")
        for folder in [prefs,output] { try fm.createDirectory(at:folder,withIntermediateDirectories:true) }
        let file=prefs.appendingPathComponent("config.json");let initial=try JSONEncoder().encode(AppConfig());try initial.write(to:file)
        let now=Date();let executable="/Applications/Blender.app/Contents/MacOS/Blender"
        let identity=NativeProcessIdentity(pid:123,birthSeconds:UInt64(now.timeIntervalSince1970)-20,birthMicroseconds:3,executable:executable)
        let sample=NativeProcessSnapshot(identity:identity,arguments:[executable,"-b",root.path+"/scene.blend","-o",output.path+"/f####.png","-f","1"])
        let reader=PausedNativeReader(sample);defer { reader.release.signal() }
        let worker=NativeRenderDiscovery(reader:reader)
        let task=Task { await worker.collect(store:RenderConfigStore(root:prefs),links:[:],writable:true) }
        try await wait(reader.began);let started=Date();task.cancel();let result=await task.value
        check(Date().timeIntervalSince(started)<0.3 && result.health.partial && result.observations.isEmpty,"native cancellation waits on IO or publishes late observation")
        reader.release.signal();try await wait(reader.finished);try await Task.sleep(for:.milliseconds(30))
        let names=try fm.contentsOfDirectory(at:prefs,includingPropertiesForKeys:nil)
        check(try Data(contentsOf:file)==initial && !names.contains {$0.lastPathComponent.hasPrefix("config.before-")},"native callback persists after cancellation")
        // Kernel layout fixture: argc bounds argv. The trailing environment is neither decoded nor projected.
        var argc:Int32=2
        var buffer=withUnsafeBytes(of:&argc) { Array($0) }
        buffer += Array((executable+"\0\0\0"+executable+"\0-b\0").utf8)
        buffer += Array("TOKEN=synthetic-environment-secret\0USER=synthetic-user\0".utf8)
        let decoded=NativeProcessReader.decodeArguments(buffer,size:buffer.count,executable:executable)
        check(decoded == [executable,"-b"],"decoder crosses argc into environment")
        check(NativeProcessReader.decodeArguments(buffer,size:3,executable:executable)==nil,"invalid argv buffer accepted")
        let scripted=NativeProcessSnapshot(identity:identity,arguments:[executable,"-b",root.path+"/scene.blend","--python",root.path+"/render.py","--","TOKEN=synthetic-private-argument"])
        let observation=NativeRenderCommandParser.parse(scripted,at:now)!
        let persisted=String(data:try JSONEncoder().encode(observation.dashboard(entries:[])),encoding:.utf8)!
        check(!persisted.contains("synthetic-private-argument") && !persisted.contains("arguments"),"raw argv persists into catalogue")
        print("NativeCancellationPrivacyTests: \(checks) assertions PASS; cancelled IO zero writes, argc/environment and raw argv boundaries")
    }
}
