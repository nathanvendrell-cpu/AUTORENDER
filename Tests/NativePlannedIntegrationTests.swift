import Foundation
import Darwin

struct PlannedFixtureReader:NativeProcessReading {
    let snapshot:NativeProcessSnapshot
    func read() -> NativeProcessRead { NativeProcessRead(snapshots:[snapshot]) }
}
final class DisappearingPlannedReader:NativeProcessReading {
    let snapshot:NativeProcessSnapshot;private var count=0
    init(_ snapshot:NativeProcessSnapshot) { self.snapshot=snapshot }
    func read() -> NativeProcessRead { count += 1;return NativeProcessRead(snapshots:count==1 ? [snapshot] : []) }
}
@main enum NativePlannedIntegrationTests {
    static var checks=0
    static func check(_ value:Bool,_ message:String) {checks+=1;precondition(value,message)}
    static func main() async throws {
        let fm=FileManager.default
        let root=URL(fileURLWithPath:"/private/tmp").appendingPathComponent("autoren-planned-integration-"+UUID().uuidString)
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? fm.removeItem(at:root) }
        let output=root.appendingPathComponent("renders");try fm.createDirectory(at:output,withIntermediateDirectories:true)
        let metadata=root.appendingPathComponent("progress.json");let scene=root.appendingPathComponent("scene.blend").path
        let now=Date();let identity=NativeProcessIdentity(pid:345,birthSeconds:UInt64(now.timeIntervalSince1970)-60,birthMicroseconds:3,executable:"/Applications/Blender.app/Contents/MacOS/Blender")
        let reader=PlannedFixtureReader(snapshot:NativeProcessSnapshot(identity:identity,arguments:[identity.executable,"-b",scene,"--python",root.path+"/render.py"]))
        let store=RenderConfigStore(root:root.appendingPathComponent("prefs"))
        var source=NativeMetadataSourceConfig(processIdentity:identity,scene:scene,metadataPath:metadata.path,outputRoot:output.path,filenamePattern:"frame_####.png")
        source.projectID="project:fixture";source.workID="work:fixture";source.versionID="version:fixture";source.workType = .video
        _=try store.update { $0.nativeMetadataSources["fixture"]=source }
        let payload:[String:Any]=["planned":[1,2,3],"completed":[["frame":2,"seconds":2]]]
        try JSONSerialization.data(withJSONObject:payload).write(to:metadata)
        for frame in [1,2] {
            let file=output.appendingPathComponent(String(format:"frame_%04d.png",frame));try Data("SIMULATED stable bytes".utf8).write(to:file)
            try fm.setAttributes([.modificationDate:now.addingTimeInterval(-10)],ofItemAtPath:file.path)
        }
        let worker=NativeRenderDiscovery(reader:reader)
        var result=await worker.collect(store:store,links:[:],writable:true,at:now)
        check(result.observations.first?.completed==nil && result.observations.first?.declaredTotal==3,"first mapped sample invents determinate progress")
        check(result.observations.first?.outputRoot==AppConfig.normalizedMacFolder(output.path) && result.config?.macFolders.contains(AppConfig.normalizedMacFolder(output.path))==true,"mapped output root not imported")
        result=await worker.collect(store:store,links:[:],writable:true,at:now.addingTimeInterval(2))
        let observation=result.observations.first!
        check(observation.completed==2 && observation.declaredTotal==3,"completed hints omit SKIP file or become numerator")
        check(observation.dashboard(entries:[]).rawProgress?.completed==2,"verified planned numerator not projected")
        check(observation.projectID==source.projectID && observation.workID==source.workID && observation.versionID==source.versionID && observation.workType == .video,"explicit business context lost or inferred from PNG")
        check(!observation.renderCommand && !observation.metadataAdvanced && observation.dashboard(entries:[]).activity == .unknown,"script/mapping or unchanged files imply running")
        // Change configured context in the same dictionary without dropping an opaque future sibling.
        let configURL=store.root.appendingPathComponent("config.json")
        var doc=try JSONSerialization.jsonObject(with:Data(contentsOf:configURL)) as! [String:Any]
        var mappings=doc["nativeMetadataSources"] as! [String:[String:Any]]
        mappings["fixture"]!["futureField"]="preserve";doc["nativeMetadataSources"]=mappings
        try JSONSerialization.data(withJSONObject:doc).write(to:configURL)
        _=try store.update { $0.nativeMetadataSources["fixture"]?.projectID="project:updated" }
        let after=try JSONSerialization.jsonObject(with:Data(contentsOf:configURL)) as! [String:Any]
        check(((after["nativeMetadataSources"] as? [String:[String:Any]])?["fixture"]?["futureField"] as? String)=="preserve","same mapping mutation loses opaque future field")
        result=await worker.collect(store:store,links:[:],writable:false,at:now.addingTimeInterval(4))
        check(result.observations.first?.projectID=="project:updated","configured file is not reread dynamically")
        try fm.removeItem(at:metadata);check(mkfifo(metadata.path,0o600)==0,"fixture FIFO failed")
        let started=Date();result=await worker.collect(store:store,links:[:],writable:true)
        check(Date().timeIntervalSince(started)<0.3 && result.health.partial && result.observations.first?.completed==nil,"mapped metadata FIFO blocks or preserves stale counts")
        let reused=NativeProcessIdentity(pid:identity.pid,birthSeconds:identity.birthSeconds+1,birthMicroseconds:identity.birthMicroseconds,executable:identity.executable)
        let other=NativeRenderDiscovery(reader:PlannedFixtureReader(snapshot:NativeProcessSnapshot(identity:reused,arguments:reader.snapshot.arguments)))
        result=await other.collect(store:store,links:[:],writable:false)
        check(result.observations.first?.completed==nil && result.health.partial,"reused PID accepts old mapping")
        let disappearing=NativeRenderDiscovery(reader:DisappearingPlannedReader(reader.snapshot))
        let ended=await disappearing.collect(store:store,links:[:],writable:true)
        check(ended.observations.isEmpty && ended.config==nil,"process vanished during filesystem IO is published or imported")
        print("NativePlannedIntegrationTests: \(checks) assertions PASS; dynamic opt-in mapping, two reads, SKIP-inclusive verified outputs, private context and FIFO safety")
    }
}
