import Foundation

final class DetectionReader: NativeProcessReading {
    var snapshots:[NativeProcessSnapshot]=[]
    var afterRead:[NativeProcessSnapshot]?;var reads=0
    func read()->NativeProcessRead {reads += 1;return NativeProcessRead(snapshots:reads%2==0 ? (afterRead ?? snapshots) : snapshots)}
}
actor DetectionGate {
    var entered=false;var continuation:CheckedContinuation<Void,Never>?
    func wait() async {entered=true;await withCheckedContinuation{continuation=$0}}
    func release(){continuation?.resume();continuation=nil}
}
@main enum ActiveDetectionRegressionTests {
    static var checks=0;static var failures:[String]=[]
    static func check(_ yes:Bool,_ message:String){checks+=1;if !yes {failures.append(message);print("FAIL: "+message)}}
    @MainActor static func main() async throws {
        let fm=FileManager.default,root=URL(fileURLWithPath:CommandLine.arguments[1]);let now=Date()
        let sources=try JSONDecoder().decode([ShadowDeclaredSource].self,from:Data(contentsOf:root.appendingPathComponent("sources.json")))
        let active=try Data(contentsOf:root.appendingPathComponent("active.json"))
        let terminal=try Data(contentsOf:root.appendingPathComponent("terminal.json"))
        let nativeRoot=root.appendingPathComponent("native");try fm.createDirectory(at:nativeRoot,withIntermediateDirectories:true)
        let store=RenderConfigStore(root:root.appendingPathComponent("prefs")),reader=DetectionReader()
        let id=NativeProcessIdentity(pid:501,birthSeconds:UInt64(now.timeIntervalSince1970)-60,birthMicroseconds:1,executable:"/fixture/bin/ffmpeg")
        let args=[id.executable,"-i",nativeRoot.path+"/input.mp4","-c:v","libx264","-frames:v","20",nativeRoot.path+"/output.mp4"]
        reader.snapshots=[NativeProcessSnapshot(identity:id,arguments:args)]
        let worker=NativeRenderDiscovery(reader:reader)
        var found=await worker.collect(store:store,links:[:],writable:false,at:now)
        check(found.observations.first?.renderCommand==true,"fixture recognized as explicit ffmpeg encoding")
        check(found.observations.first?.dashboard(entries:[],now:now).isDetectedActiveRender==true,"explicit ffmpeg absent from active renders")
        found=await worker.collect(store:store,links:[:],writable:false,at:now.addingTimeInterval(180))
        let longJob=found.observations.first!.dashboard(entries:[],now:now.addingTimeInterval(180))
        check(longJob.isDetectedActiveRender && !longJob.hasRecentProgress(at:now.addingTimeInterval(180)),"long encoding without output loses active qualification")
        check(!found.observations.first!.dashboard(entries:[],now:now.addingTimeInterval(240)).isDetectedActiveRender,"expired native sample remains active")
        check(longJob.rawCount==nil && longJob.rawProgress==nil && !longJob.isFinishedRender,"output-free encoding invents progress or completion")
        var bad=args;bad.insert("-unknown",at:1);reader.snapshots=[NativeProcessSnapshot(identity:id,arguments:bad)]
        found=await worker.collect(store:store,links:[:],writable:false,at:now)
        check(found.observations.first?.dashboard(entries:[],now:now).isDetectedActiveRender==false,"ambiguous ffmpeg called active")
        reader.snapshots=[NativeProcessSnapshot(identity:id,arguments:args)];reader.afterRead=[]
        found=await worker.collect(store:store,links:[:],writable:false,at:now)
        check(found.observations.isEmpty && found.historyObservations.isEmpty,"vanished ffmpeg published active or completed")
        let reused=NativeProcessIdentity(pid:id.pid,birthSeconds:id.birthSeconds+1,birthMicroseconds:1,executable:id.executable)
        reader.afterRead=[NativeProcessSnapshot(identity:reused,arguments:args)]
        found=await worker.collect(store:store,links:[:],writable:false,at:now)
        check(found.observations.isEmpty,"reused PID inherits active encoding")
        reader.afterRead=nil;reader.snapshots=[NativeProcessSnapshot(identity:id,arguments:nil)]
        found=await worker.collect(store:store,links:[:],writable:false,at:now)
        check(found.observations.first?.dashboard(entries:[],now:now).isDetectedActiveRender==false,"unreadable command becomes active")
        let connectionRoot=root.appendingPathComponent("shadow");try fm.createDirectory(at:connectionRoot,withIntermediateDirectories:true)
        let key=connectionRoot.appendingPathComponent("fixture-key");try Data("not a credential".utf8).write(to:key)
        let connection=connectionRoot.appendingPathComponent("connection.json")
        func writeConnection(_ host:String="fixture.invalid") throws {try JSONSerialization.data(withJSONObject:["host":host,"user":"fixture","identityFile":key.path]).write(to:connection,options:.atomic)}
        try writeConnection()
        let observer=ShadowRunDiscovery(root:connectionRoot,loader:{_ in active})
        check(await observer.hasConfiguredConnection(),"fixture connection rejected")
        await observer.refresh(sources,force:true)
        check(observer.jobs.first?.isDetectedActiveRender==true,"qualified Shadow worker rejected")
        check(observer.jobs.first?.hasRecentProgress()==false,"unchanged worker invents recent progress")
        let cached=try Data(contentsOf:connectionRoot.appendingPathComponent("shadow-runs-last-good.json"))
        try fm.removeItem(at:connection)
        check(await observer.hasConfiguredConnection()==false,"missing connection accepted")
        check(observer.jobs.allSatisfy{!$0.isDetectedActiveRender && !$0.isFresh} && observer.health.isStale,"missing connection leaves fresh ghost worker")
        check(try Data(contentsOf:connectionRoot.appendingPathComponent("shadow-runs-last-good.json"))==cached,"connection invalidation changes durable snapshot")
        try writeConnection();check(await observer.hasConfiguredConnection(),"reconnection rejected")
        await observer.refresh(sources,force:true)
        check(observer.jobs.first?.isDetectedActiveRender==true,"reconnection cannot reacquire qualified worker")
        try writeConnection("replacement.invalid")
        check(await observer.hasConfiguredConnection(),"replacement connection rejected")
        check(observer.jobs.allSatisfy{!$0.isFresh && !$0.isDetectedActiveRender},"replacement connection inherits previous fresh worker")
        await observer.refresh(sources)
        check(observer.jobs.first?.isDetectedActiveRender==true,"replacement connection remains throttled after invalidation")
        var changedSources=sources;changedSources[0].expectedScriptSHA256=String(repeating:"d",count:64)
        await observer.refresh(changedSources)
        check(observer.jobs.isEmpty && observer.health.isStale,"source change inside throttle retains foreign worker")
        await observer.refresh(sources)
        check(observer.jobs.first?.isDetectedActiveRender==true,"source change cannot reacquire original scope")
        try Data("broken".utf8).write(to:connection)
        check(await observer.hasConfiguredConnection()==false && observer.jobs.allSatisfy{!$0.isFresh},"malformed connection leaves fresh worker")
        observer.stop();await observer.waitForShutdown()
        // A late response must be rejected even without a second preflight invocation.
        try writeConnection();let gate=DetectionGate()
        let late=ShadowRunDiscovery(root:connectionRoot,loader:{_ in await gate.wait();return active})
        check(await late.hasConfiguredConnection(),"late fixture connection rejected")
        let request=Task {await late.refresh(sources,force:true)}
        while !(await gate.entered){try await Task.sleep(for:.milliseconds(1))}
        try fm.removeItem(at:connection);await gate.release();await request.value
        check(late.jobs.allSatisfy{!$0.isFresh && !$0.isDetectedActiveRender} && late.health.isStale,"late response reactivates removed connection")
        late.stop();await late.waitForShutdown()
        try writeConnection();let replacedGate=DetectionGate()
        let replaced=ShadowRunDiscovery(root:connectionRoot,loader:{_ in await replacedGate.wait();return active})
        check(await replaced.hasConfiguredConnection(),"replaced-flight fixture connection rejected")
        let replacedRequest=Task {await replaced.refresh(sources,force:true)}
        while !(await replacedGate.entered){try await Task.sleep(for:.milliseconds(1))}
        try writeConnection("new-target.invalid")
        await replacedGate.release();await replacedRequest.value
        check(replaced.jobs.allSatisfy{!$0.isFresh && !$0.isDetectedActiveRender} && replaced.health.isStale,"late response accepted after connection target changes")
        replaced.stop();await replaced.waitForShutdown()
        try writeConnection();let terminalObserver=ShadowRunDiscovery(root:root.appendingPathComponent("terminal-cache"),loader:{_ in terminal})
        await terminalObserver.refresh(sources,force:true)
        check(terminalObserver.jobs.first?.isFinishedRender==true,"valid terminal fixture rejected")
        check(await terminalObserver.hasConfiguredConnection()==false,"absent terminal connection accepted")
        check(terminalObserver.jobs.first?.isFinishedRender==true && terminalObserver.jobs.first?.isFresh==false,"connection loss erases technical terminal history")
        terminalObserver.stop();await terminalObserver.waitForShutdown()
        print("ActiveDetectionRegressionTests: \(checks) checks, \(failures.count) failures")
        if !failures.isEmpty {exit(1)}
    }
}
