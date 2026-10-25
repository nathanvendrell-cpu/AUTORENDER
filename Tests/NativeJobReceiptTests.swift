import Foundation
import CryptoKit

final class ReceiptFixtureProcesses:NativeProcessReading {
    private let lock=NSLock();private var snapshots:[NativeProcessSnapshot]=[]
    func set(_ values:[NativeProcessSnapshot]){lock.lock();snapshots=values;lock.unlock()}
    func read()->NativeProcessRead {lock.lock();defer{lock.unlock()};return NativeProcessRead(snapshots:snapshots)}
}
@main enum NativeJobReceiptTests {
    static var checks=0
    static func check(_ value:Bool,_ label:String){checks += 1;precondition(value,label)}
    static func sha(_ data:Data)->String{SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    static func json(_ object:Any,_ url:URL)throws {try JSONSerialization.data(withJSONObject:object,options:.sortedKeys).write(to:url)}
    static func iso(_ date:Date)->String {let f=ISO8601DateFormatter();f.formatOptions=[.withInternetDateTime,.withFractionalSeconds];return f.string(from:date)}
    @MainActor static func main()async throws {
        let fm=FileManager.default,root=fm.temporaryDirectory.appendingPathComponent("autoren-receipt-tests-"+UUID().uuidString).resolvingSymlinksInPath()
        try fm.createDirectory(at:root,withIntermediateDirectories:true);defer{try? fm.removeItem(at:root)}
        let now=Date(),born=Date(timeIntervalSince1970:floor(now.timeIntervalSince1970)-10)
        let identity=NativeProcessIdentity(pid:123,birthSeconds:UInt64(born.timeIntervalSince1970),birthMicroseconds:0,executable:"/Applications/Blender.app/Contents/MacOS/Blender")
        let scene=root.appendingPathComponent("scene.blend"),script=root.appendingPathComponent("producer.py"),jobdir=root.appendingPathComponent("job")
        try Data("synthetic scene; never loaded".utf8).write(to:scene);try Data("# synthetic producer; never run".utf8).write(to:script)
        for p in [scene,script]{try fm.setAttributes([.modificationDate:born.addingTimeInterval(-1)],ofItemAtPath:p.path)}
        try fm.createDirectory(at:jobdir.appendingPathComponent("frames"),withIntermediateDirectories:true)
        let settings:[String:Any]=["frames":720,"samples":64]
        let manifest:[String:Any]=["createdUTC":iso(born.addingTimeInterval(-2)),"scene":scene.path,"renderer":script.path,"sceneSHA256":sha(try Data(contentsOf:scene)),"rendererSHA256":sha(try Data(contentsOf:script)),"blender":identity.executable,"settings":settings]
        try json(manifest,jobdir.appendingPathComponent("job.json"))
        var receipt:[String:Any]=["utc":iso(born.addingTimeInterval(1)),"state":"RUNNING","pid":123,"jobSHA256":sha(try Data(contentsOf:jobdir.appendingPathComponent("job.json"))),"sceneSHA256":manifest["sceneSHA256"]!,"settings":settings,"completeFrames":0,"records":[]]
        let receiptURL=jobdir.appendingPathComponent("frames_receipt.json");try json(receipt,receiptURL)
        let reader=NativeJobReceiptReader()
        var value=try reader.read(directory:jobdir.path,identity:identity,scene:scene.path,renderer:script.path,now:now)
        var observation=NativeRenderObservation(identity:identity,producer:"Blender",observedAt:now);value.apply(to:&observation)
        check(observation.dashboard(entries:[],now:now).isDetectedActiveRender,"RUNNING first long frame qualifies")
        check(observation.completed==0 && observation.declaredTotal==720 && !observation.metadataAdvanced,"honest declared counter")
        check(!observation.stableOutputCountVerified && observation.dashboard(entries:[]).finalOutputProof==nil,"receipt never attests files")
        _=try reader.read(directory:jobdir.path,identity:identity,scene:scene.path,renderer:script.path,now:now)
        check(reader.hashReads==2,"unchanged scene/script hashes cached")
        let reused=NativeProcessIdentity(pid:123,birthSeconds:identity.birthSeconds+2,birthMicroseconds:0,executable:identity.executable)
        do {_=try reader.read(directory:jobdir.path,identity:reused,scene:scene.path,renderer:script.path,now:now);check(false,"PID reuse accepted")}catch{check(true,"PID reuse rejected")}
        observation.processPresent=false;value.apply(to:&observation)
        check(observation.dashboard(entries:[]).activity == .resumeRequired && !observation.dashboard(entries:[]).isDetectedActiveRender,"RUNNING absent PID means interrupted")
        receipt["state"]="STOPPED_OR_FAILED";try json(receipt,receiptURL)
        let log=jobdir.appendingPathComponent("blender_stdout.txt");try Data("RuntimeError MTLCommandBufferErrorDomain Code 8 InsufficientMemory".utf8).write(to:log)
        try fm.setAttributes([.modificationDate:born.addingTimeInterval(2)],ofItemAtPath:log.path)
        value=try reader.read(directory:jobdir.path,identity:identity,scene:scene.path,renderer:script.path,now:now)
        value.apply(to:&observation)
        check(observation.stage.contains("mémoire GPU insuffisante") && observation.completed==0,"dated GPU memory failure retained")
        var complete=receipt;complete["state"]="COMPLETE_720_REAL_FRAMES";complete["completeFrames"]=720
        complete["records"]=(1...720).map{["frame":$0,"sha256":sha(Data("fixture-frame-\($0)".utf8)),"bytes":1] as [String:Any]}
        try json(complete,receiptURL)
        let finished=try reader.read(directory:jobdir.path,identity:identity,scene:scene.path,renderer:script.path,now:now)
        var ended=observation;finished.apply(to:&ended)
        check(ended.dashboard(entries:[]).isFinishedRender && !ended.dashboard(entries:[]).isDetectedActiveRender,"producer COMPLETE is terminal and never active")
        check(!ended.stableOutputCountVerified && ended.dashboard(entries:[]).finalOutputProof==nil,"producer COMPLETE never grants physical file authority")
        try json(receipt,receiptURL)
        receipt["jobSHA256"]=String(repeating:"0",count:64);try json(receipt,receiptURL)
        do{_=try reader.read(directory:jobdir.path,identity:identity,scene:scene.path,renderer:script.path,now:now);check(false,"wrong manifest accepted")}catch{check(true,"manifest mismatch rejected")}
        receipt["jobSHA256"]=sha(try Data(contentsOf:jobdir.appendingPathComponent("job.json")));try json(receipt,receiptURL)
        let historical=observation.dashboard(entries:[],now:now)
        let recovered=try NativeJobReceiptReader().backfill([historical],now:now,permit:nil)
        check(recovered.count==1 && recovered.first?.identity==identity,"bounded historical recovery requires exact PID/birth/catalogue identity")
        let restored=try NativeJobReceiptReader().read(binding:recovered[0],now:now)
        check(restored.completed==0 && restored.state=="STOPPED_OR_FAILED","persisted binding restores stopped receipt after reader restart")
        var lookalike=historical;lookalike.id="mac:native:"+String(repeating:"f",count:64)
        let rejected=try NativeJobReceiptReader().backfill([lookalike],now:now,permit:nil)
        check(rejected.isEmpty,"lookalike source names cannot adopt a different catalogue identity")
        let args=[identity.executable,"--background",scene.path,"--python",script.path,"--",jobdir.path]
        let parsed=NativeRenderCommandParser.parse(NativeProcessSnapshot(identity:identity,arguments:args),at:now)!
        check(parsed.jobDirectory==jobdir.path && !parsed.renderCommand,"argv job-directory candidate only")
        var old=observation.dashboard(entries:[]);old.baseProjectID="binding:fixture";old.projectID="unclassified:mac-local";old.sceneID="scene:keep";old.libraryVersion="v050";old.archivedAt=born;old.sourceContext=nil
        var config=AppConfig();config.projectBindings=[RenderProjectBinding(id:"binding:fixture",title:"Fixture",roots:[RenderProjectRoot(path:root.path,namespace:"mac-local")])]
        let classified=RenderContextResolver(config:config).apply(old)
        check(classified.projectTitle=="Fixture" && classified.hasVerifiedProjectContext==false && classified.sceneID=="scene:keep" && classified.libraryVersion=="v050" && classified.archivedAt==born,"offline display binding keeps identity without move authority")
        old.baseProjectID="other";check(RenderContextResolver(config:config).apply(old).projectTitle=="À classer","no label fallback")
        let cfg=root.appendingPathComponent("preferences");try fm.createDirectory(at:cfg,withIntermediateDirectories:true)
        try json(["opaque":"keep","shadowMonitoringEnabled":true],cfg.appendingPathComponent("config.json"))
        let store=RenderConfigStore(root:cfg);_=try store.update{$0.shadowMonitoringEnabled=false}
        let readback=try JSONSerialization.jsonObject(with:Data(contentsOf:cfg.appendingPathComponent("config.json"))) as! [String:Any]
        check(readback["opaque"] as? String=="keep" && readback["shadowMonitoringEnabled"] as? Bool==false,"typed disable persists and preserves unknown keys")
        CollectorProcess.setRemoteAccessEnabled(false)
        let disabled=await CollectorProcess.asyncRun(arguments:[],timeout:1,fixtureHelperURL:URL(fileURLWithPath:"/must-never-be-launched.py"))
        check(disabled==nil && !CollectorProcess.remoteAccessEnabled,"transport disabled before helper selection")
        let modelRoot=root.appendingPathComponent("model");try fm.createDirectory(at:modelRoot,withIntermediateDirectories:true)
        try json(["opaque":"keep","shadowMonitoringEnabled":true],modelRoot.appendingPathComponent("config.json"))
        let model=MonitorModel(storageRoot:modelRoot,nativeReader:ReceiptFixtureProcesses(),macOnly:true)
        let modelConfig=try JSONSerialization.jsonObject(with:Data(contentsOf:modelRoot.appendingPathComponent("config.json"))) as! [String:Any]
        check(!model.shadowMonitoringEnabled && modelConfig["shadowMonitoringEnabled"] as? Bool==false && modelConfig["opaque"] as? String=="keep","macOnly persists false before collectors and preserves opaque config")
        model.stop();await model.waitForShutdown()
        let helper=URL(fileURLWithPath:CommandLine.arguments[1]),directScript=root.appendingPathComponent("direct.py"),output=root.appendingPathComponent("expected.png")
        try Data("import bpy\nfrom pathlib import Path\ns=bpy.context.scene\ns.render.filepath=str(Path(\"\(output.path)\"))\nbpy.ops.render.render(write_still=True)\n".utf8).write(to:directScript)
        try fm.setAttributes([.modificationDate:born.addingTimeInterval(-1)],ofItemAtPath:directScript.path)
        let processes=ReceiptFixtureProcesses(),snapshot=NativeProcessSnapshot(identity:identity,arguments:[identity.executable,"--background",scene.path,"--python",directScript.path])
        processes.set([snapshot]);let worker=NativeRenderDiscovery(reader:processes,scripts:NativeScriptContractReader(helper:helper))
        let active=await worker.collect(store:store,links:[:],writable:false,at:now)
        check(active.observations.count==1 && active.observations[0].declaredTotal==1 && active.observations[0].dashboard(entries:[],now:now).isDetectedActiveRender,"direct AST still qualifies 1, never 720")
        let png=Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jbxkAAAAASUVORK5CYII=")!
        try png.write(to:output);try fm.setAttributes([.modificationDate:born.addingTimeInterval(3)],ofItemAtPath:output.path)
        processes.set([])
        let ended1=await worker.collect(store:store,links:[:],writable:false,at:now.addingTimeInterval(1))
        check(ended1.observations.isEmpty && ended1.historyObservations.first?.completed==nil,"PID disappearance removes active before stable proof")
        let ended2=await worker.collect(store:store,links:[:],writable:false,at:now.addingTimeInterval(2))
        check(ended2.historyObservations.first?.completed==1 && ended2.historyObservations.first?.dashboard(entries:[]).finalOutputProof==nil,"exact PNG stable twice, no library finality")
        print("NativeJobReceiptTests: \(checks) assertions PASS; synthetic fixtures only, no render/network")
    }
}
