import Foundation
import Darwin
final class SnapshotFeed:NativeProcessReading,@unchecked Sendable {
 var snapshots:[NativeProcessSnapshot];var final:[NativeProcessSnapshot]?;var partial=false;var finalPartial=false
 private let lock=NSLock();private var calls=0
 init(_ snapshots:[NativeProcessSnapshot]){self.snapshots=snapshots}
 func read()->NativeProcessRead {lock.lock();defer{lock.unlock()};calls+=1;return NativeProcessRead(snapshots:calls%2==0 ? (final ?? snapshots) : snapshots,partial:calls%2==0 ? finalPartial : partial)}
}
@main enum NativeScriptIntegrationTests {
 static var checks=0
 static func check(_ value:Bool,_ message:String){checks+=1;precondition(value,message)}
 static func checkCatalogue(root:URL,active:RenderDashboardJob,terminal:RenderDashboardJob) async throws {
  let service=RenderCatalogService(root:root.appendingPathComponent("fixture-catalogue"))
  func input(_ jobs:[RenderDashboardJob],config:AppConfig=AppConfig())->RenderCatalogInput {
   var value=RenderCatalogInput(revision:1,macJobs:[],shadow:nil,declaration:nil,config:config,knownFolders:[:],entries:[],macEntries:[],folderEntries:[],shadowEntries:[],shadowFolderEntries:[],macHealth:SourceHealth(),shadowHealth:SourceHealth(),folderHealth:SourceHealth(),remoteHealth:SourceHealth())
   value.preparedJobs=jobs;return value
  }
  let live=await service.build(input([active]))!
  check(live.jobs.first?.workTitle=="left" && live.jobs.first?.versionLabel=="final","catalogue overwrites qualified source labels")
  check(live.jobs.first?.isDetectedActiveRender==true,"catalogue loses task qualification")
  let ended=await service.build(input([terminal]))!
  check(ended.jobs.first?.isFinishedRender==true,"current technical completion missing")
  let retained=await service.build(input([]))!
  check(retained.jobs.first?.isFinishedRender==true && retained.jobs.first?.retainedHistorical==true,"historical technical completion not retained")
  let reloaded=RenderCatalogService(root:root.appendingPathComponent("fixture-catalogue"))
  let after=await reloaded.build(input([]))!
  check(after.jobs.first?.isFinishedRender==true && after.jobs.first?.versionLabel=="final","persisted terminal/source label lost on reload")
  var oldObject=try JSONSerialization.jsonObject(with:JSONEncoder().encode(active)) as! [String:Any]
  oldObject.removeValue(forKey:"taskQualification");oldObject.removeValue(forKey:"progressObservedAt")
  let old=try JSONDecoder().decode(RenderDashboardJob.self,from:JSONSerialization.data(withJSONObject:oldObject))
  check(!old.isDetectedActiveRender,"old PID-only running record promoted qualified")
  var legacy=old;legacy.id="mac:legacy-fixture"
  var legacyConfig=AppConfig();legacyConfig.jobArchives[legacy.id]=Date(timeIntervalSince1970:100)
  let legacyInput=input([legacy],config:legacyConfig)
  let legacySnapshot=await service.build(legacyInput)!
  check(legacySnapshot.jobs.first(where:{$0.id==legacy.id})?.isArchived==true && !legacySnapshot.reactivatedArchiveIDs.contains(legacy.id),"PID-only legacy task erased an existing archive")
  check(legacySnapshot.stateCounts.running==0,"catalogue running count includes unqualified PID")
  let shadow=RenderDashboardJob(id:"shadow:fixture",title:"fixture",projectID:"fixture",source:.shadowMonitor,workType:.video,rawCount:6,postCount:5,rawProgress:RenderProgress(completed:6,total:6),postProgress:RenderProgress(completed:5,total:6),totalProvenance:"fixture",activity:.countsReached,isFresh:true,observedAt:Date(),lastActivity:nil,historicalMedianSeconds:nil,sampledOutputsLastHour:nil,eta:nil,process:nil,gpu:nil,gpuRaw:nil,plans:[],tasks:[],stageDescription:nil,previewEntries:[])
  check(!shadow.isFinishedRender,"raw/post were summed or partial post called finished")
 }
 static func main() async throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1]);let helper=URL(fileURLWithPath:CommandLine.arguments[2]);let fixtures=root.appendingPathComponent("fixture")
  let scene=fixtures.appendingPathComponent("scene/fixture.blend");let script=fixtures.appendingPathComponent("scripts/driver.py")
  let now=Date();let born=UInt64(now.timeIntervalSince1970-5)
  let identity=NativeProcessIdentity(pid:123,birthSeconds:born,birthMicroseconds:0,executable:"/fixture/Blender.app/Contents/MacOS/Blender")
  let arguments=[identity.executable,"-b",scene.path,"--python",script.path,"--","--variant","left","--mode","final","--frames","all"]
  let snapshot=NativeProcessSnapshot(identity:identity,arguments:arguments);let reader=SnapshotFeed([snapshot]);let scripts=NativeScriptContractReader(helper:helper)
  let discovery=NativeRenderDiscovery(reader:reader,scripts:scripts);let store=RenderConfigStore(root:root.appendingPathComponent("empty-config"))
  let metadata=fixtures.appendingPathComponent("metadata/PROGRESS_left_final.json")
  let held=root.appendingPathComponent("first-frame-progress.held");try FileManager.default.moveItem(at:metadata,to:held)
  let coldStart=Date()
  let firstFrame=await discovery.collect(store:store,links:[:],writable:false,at:now)
  let coldSeconds=Date().timeIntervalSince(coldStart)
  check(firstFrame.observations.first?.declaredTotal==6 && firstFrame.observations.first?.completed==nil,"first frame fabricated a counter")
  check(firstFrame.observations.first?.dashboard(entries:[],now:now).isDetectedActiveRender==true,"qualified task hidden before first progress JSON")
  try FileManager.default.moveItem(at:held,to:metadata)
  let first=await discovery.collect(store:store,links:[:],writable:false,at:now)
  check(first.observations.count==1,"automatic job missing")
  let a=first.observations[0];check(a.declaredTotal==6 && a.completed==nil,"first reading fabricates stable count")
  check(a.outputRoot != nil && a.outputPattern?.hasSuffix("frame_####.png")==true,"scope not automatically derived")
  check(a.automaticComponentTitle=="left" && a.automaticVersionLabel=="final","qualified labels missing")
  check(!a.metadataAdvanced && a.dashboard(entries:[],now:now).isDetectedActiveRender,"qualified first frame lost task activity")
  let warmStart=Date()
  let second=await discovery.collect(store:store,links:[:],writable:false,at:now.addingTimeInterval(3))
  let warmSeconds=Date().timeIntervalSince(warmStart)
  check(second.observations.first?.completed==2 && second.observations.first?.declaredTotal==6,"stable exact files counted incorrectly")
  check(second.observations.first?.versionID==a.versionID,"version changes every observation")
  try JSONSerialization.data(withJSONObject:["coldCollectSeconds":coldSeconds,"warmCollectSeconds":warmSeconds,"unchangedContractHelperInvocations":scripts.helperInvocationCount,"plannedFrames":6,"scope":"synthetic fixture only; not a real 241-frame runtime benchmark"] ).write(to:root.appendingPathComponent("cache-metrics.json"))
  let output=fixtures.appendingPathComponent("outputs/left_final");let new=output.appendingPathComponent("frame_0003.png")
  let png=Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
  try png.write(to:new);try FileManager.default.setAttributes([.modificationDate:now.addingTimeInterval(4)],ofItemAtPath:new.path)
  let third=await discovery.collect(store:store,links:[:],writable:false,at:now.addingTimeInterval(5))
  check(third.observations.first?.metadataAdvanced==true,"scoped new expected file not positive activity")
  check(third.observations.first?.completed==2,"new unstable file counted prematurely")
  let nextIdentity=NativeProcessIdentity(pid:124,birthSeconds:born+1,birthMicroseconds:0,executable:identity.executable)
  let nextSnapshot=NativeProcessSnapshot(identity:nextIdentity,arguments:arguments);let nextReader=SnapshotFeed([nextSnapshot]);let nextDiscovery=NativeRenderDiscovery(reader:nextReader,scripts:scripts)
  let next=await nextDiscovery.collect(store:store,links:[:],writable:false,at:now.addingTimeInterval(7))
  check(next.observations.first?.versionID==a.versionID,"worker changes version identity")
  check(next.observations.first?.completed==nil && next.observations.first?.metadataAdvanced==false,"new PID borrows previous worker evidence")
  let reused=SnapshotFeed([snapshot]);reused.final=[NativeProcessSnapshot(identity:nextIdentity,arguments:arguments)]
  let race=await NativeRenderDiscovery(reader:reused,scripts:scripts).collect(store:store,links:[:],writable:false,at:now)
  check(race.observations.isEmpty,"PID/birth changed after IO accepted")
  let scriptRace=SnapshotFeed([snapshot]);var changed=arguments;changed[4]="/outside/other.py";scriptRace.final=[NativeProcessSnapshot(identity:identity,arguments:changed)]
  let badScript=await NativeRenderDiscovery(reader:scriptRace,scripts:scripts).collect(store:store,links:[:],writable:false,at:now)
  check(badScript.observations.isEmpty,"script changed after IO accepted")
  let variantRace=SnapshotFeed([snapshot]);var variantArgs=arguments;variantArgs[7]="right";variantRace.final=[NativeProcessSnapshot(identity:identity,arguments:variantArgs)]
  let changedScope=await NativeRenderDiscovery(reader:variantRace,scripts:scripts).collect(store:store,links:[:],writable:false,at:now)
  check(changedScope.observations.isEmpty,"argv scope changed after IO accepted")
  let incomplete=output.appendingPathComponent("frame_0004.png");try Data("not-a-png".utf8).write(to:incomplete)
  try FileManager.default.setAttributes([.modificationDate:now.addingTimeInterval(-10)],ofItemAtPath:incomplete.path)
  let later=await discovery.collect(store:store,links:[:],writable:false,at:now.addingTimeInterval(120))
  check(later.observations.first?.completed==3 && later.observations.first?.metadataAdvanced==false,"stale outputs or non-PNG promoted completion/activity")
  let waiting=later.observations.first!.dashboard(entries:[],now:now.addingTimeInterval(120))
  check(waiting.isDetectedActiveRender && !waiting.hasRecentProgress(at:now.addingTimeInterval(120)),"long frame drops qualified task or invents recent progression")
  check(waiting.gpu==nil && waiting.process==nil,"task qualification invented GPU/CPU metrics")
  check(scripts.helperInvocationCount==1,"unchanged static contract launches Python every poll")
  let partialReader=SnapshotFeed([snapshot]);partialReader.partial=true
  let partialDiscovery=NativeRenderDiscovery(reader:partialReader,scripts:scripts)
  _=await partialDiscovery.collect(store:store,links:[:],writable:false,at:now.addingTimeInterval(120))
  let partial=await partialDiscovery.collect(store:store,links:[:],writable:false,at:now.addingTimeInterval(123))
  check(partial.health.partial && partial.observations.first?.completed==nil && partial.observations.first?.metadataAdvanced==false,"partial coverage invents an attributed counter or recent progression")
  check(partial.observations.first?.dashboard(entries:[],now:now.addingTimeInterval(123)).isDetectedActiveRender==true,"partial global coverage hides a positive qualified task")
  let competitorIdentity=NativeProcessIdentity(pid:125,birthSeconds:born,birthMicroseconds:0,executable:identity.executable)
  let competitorArgs=[identity.executable,"-b",scene.path,"-o",output.appendingPathComponent("frame_####.png").path,"-a"]
  let competitor=NativeProcessSnapshot(identity:competitorIdentity,arguments:competitorArgs)
  let sharedReader=SnapshotFeed([snapshot,competitor]);let sharedDiscovery=NativeRenderDiscovery(reader:sharedReader,scripts:scripts)
  _=await sharedDiscovery.collect(store:store,links:[:],writable:false,at:now.addingTimeInterval(10))
  let extra=output.appendingPathComponent("frame_0005.png");try png.write(to:extra);try FileManager.default.setAttributes([.modificationDate:now.addingTimeInterval(11)],ofItemAtPath:extra.path)
  let shared=await sharedDiscovery.collect(store:store,links:[:],writable:false,at:now.addingTimeInterval(12))
  check(shared.observations.first(where:{$0.identity==identity})?.metadataAdvanced==false,"competing CLI root allowed activity attribution")
  check(shared.observations.first(where:{$0.identity==identity})?.dashboard(entries:[],now:now.addingTimeInterval(12)).isDetectedActiveRender==true && shared.observations.first(where:{$0.identity==identity})?.completed==nil,"shared output hides qualified task or attributes ambiguous counter")
  let crcFile=root.appendingPathComponent("bad-header.png");var badPNG=png;badPNG[29] ^= 1;try badPNG.write(to:crcFile)
  let fd=open(crcFile.path,O_RDONLY);defer{close(fd)}
  check(NativePlannedFrameMetadata.pngEnvelope(fd:fd,bytes:Int64(badPNG.count))==nil,"bad IHDR checksum accepted")
  let slowHelper=root.appendingPathComponent("slow-helper.py");let pidFile=root.appendingPathComponent("helper.pid")
  try Data(("import os,time\nfrom pathlib import Path\nPath("+String(reflecting:pidFile.path)+").write_text(str(os.getpid()))\ntime.sleep(10)\n").utf8).write(to:slowHelper)
  let started=Date();var failed=false
  do{_=try NativeScriptContractReader(helper:slowHelper).infer(snapshot,observation:a,permit:RenderIOPermit(seconds:3))}catch{failed=true}
  check(failed && Date().timeIntervalSince(started)<2,"helper deadline not bounded")
  let helperPID=Int32(try String(contentsOf:pidFile,encoding:.utf8))!
  check(kill(helperPID,0) == -1 && errno==ESRCH,"timed out helper remains running or zombie")
  try JSONSerialization.data(withJSONObject:["pid":helperPID,"exited":true,"reaped":true]).write(to:root.appendingPathComponent("helper-cleanup.json"))
  try Data("{broken".utf8).write(to:metadata)
  let invalid=await discovery.collect(store:store,links:[:],writable:false,at:now.addingTimeInterval(8))
  check(invalid.health.partial && invalid.observations.first?.completed==nil,"bad metadata retains attributed counter")
  try JSONSerialization.data(withJSONObject:["variant":"left","mode":"final","planned":Array(1...6),"completed":[]]).write(to:metadata)
  try JSONSerialization.data(withJSONObject:["variant":"right","mode":"final","planned":Array(1...6),"completed":[]]).write(to:metadata)
  let foreign=await discovery.collect(store:store,links:[:],writable:false,at:now.addingTimeInterval(8.2))
  check(foreign.observations.first?.completed==nil,"cache bypasses metadata variant scope guard")
  try JSONSerialization.data(withJSONObject:["variant":"left","mode":"final","planned":Array(1...6),"completed":[["frame":1.0,"seconds":1,"bytes":3]]]).write(to:metadata)
  let floated=await discovery.collect(store:store,links:[:],writable:false,at:now.addingTimeInterval(8.4))
  check(floated.observations.first?.completed==nil,"cached metadata accepts noninteger frame")
  try JSONSerialization.data(withJSONObject:["variant":"left","mode":"final","planned":Array(1...6),"completed":[]]).write(to:metadata)
  let recovered=await discovery.collect(store:store,links:[:],writable:false,at:now.addingTimeInterval(9))
  check(recovered.observations.first?.declaredTotal==6 && recovered.observations.first?.completed==nil,"metadata recovery borrows pre-error stability evidence")
  let qualified=try scripts.infer(snapshot,observation:a,permit:RenderIOPermit(seconds:2))!
  let binding=NativePlannedFrameMetadata.Binding(pid:identity.pid,birthSeconds:identity.birthSeconds,birthMicroseconds:identity.birthMicroseconds,executable:identity.executable,scene:scene.path)
  var mapping=NativePlannedFrameMetadata.Mapping(metadataPath:metadata.path,outputRoot:output.path,binding:binding,plannedKey:"planned",filenamePattern:"frame_####.png")
  let (_,stamp)=try NativePlannedFrameMetadata.readSource(metadata.path,permit:RenderIOPermit(seconds:2))
  mapping.expectedMetadata=NativePlannedFrameMetadata.Fingerprint(device:stamp.device,inode:stamp.inode+1,bytes:stamp.bytes,modified:stamp.modified)
  var fingerprintRejected=false
  do{_=try NativePlannedFrameMetadata.read(mapping:mapping,current:binding,now:now,previous:nil,check:{})}catch{fingerprintRejected=true}
  check(fingerprintRejected,"metadata replaced between AST helper and Swift accepted")
  check(qualified.descriptor.metadataFingerprint==nil,"static cache borrows old metadata proof")
  let escaped=root.appendingPathComponent("unknown.py");try Data("print('fixture only')".utf8).write(to:escaped);try FileManager.default.setAttributes([.modificationDate:now.addingTimeInterval(-20)],ofItemAtPath:escaped.path)
  var unknownArgs=arguments;unknownArgs[4]=escaped.path
  let unknownReader=SnapshotFeed([NativeProcessSnapshot(identity:identity,arguments:unknownArgs)])
  let unknown=await NativeRenderDiscovery(reader:unknownReader,scripts:scripts).collect(store:store,links:[:],writable:false,at:now)
  check(unknown.observations.first?.dashboard(entries:[],now:now).isDetectedActiveRender==false,"unqualified script PID promoted active")
  let cliArgs=[identity.executable,"-b",scene.path,"-o",output.appendingPathComponent("frame_####.png").path,"-a"]
  let cli=await NativeRenderDiscovery(reader:SnapshotFeed([NativeProcessSnapshot(identity:identity,arguments:cliArgs)]),scripts:scripts).collect(store:store,links:[:],writable:false,at:now)
  check(cli.observations.first?.dashboard(entries:[],now:now).isDetectedActiveRender==true,"explicit render command not active before first output")
  let disappeared=SnapshotFeed([snapshot]);disappeared.final=[]
  let gone=await NativeRenderDiscovery(reader:disappeared,scripts:scripts).collect(store:store,links:[:],writable:false,at:now)
  check(gone.observations.isEmpty,"disappeared process remained active or fabricated finished state")
  for frame in [4,6] {
   let file=output.appendingPathComponent(String(format:"frame_%04d.png",frame));try png.write(to:file);try FileManager.default.setAttributes([.modificationDate:now.addingTimeInterval(129)],ofItemAtPath:file.path)
  }
  _=await discovery.collect(store:store,links:[:],writable:false,at:now.addingTimeInterval(130))
  let terminal=await discovery.collect(store:store,links:[:],writable:false,at:now.addingTimeInterval(133))
  let terminalJob=terminal.observations.first!.dashboard(entries:[],now:now.addingTimeInterval(133))
  check(terminalJob.isFinishedRender && !terminalJob.isDetectedActiveRender && terminalJob.activity == .countsReached,"stable complete plan not separated as countsReached")
  var historical=terminalJob;historical.retainedHistorical=true;historical.isFresh=false
  check(historical.isFinishedRender && !historical.isDetectedActiveRender,"historical terminal observation disappeared from finished")
  let finalPartialReader=SnapshotFeed([snapshot]);finalPartialReader.finalPartial=true
  let finalPartialDiscovery=NativeRenderDiscovery(reader:finalPartialReader,scripts:scripts)
  let finalPartial=await finalPartialDiscovery.collect(store:store,links:[:],writable:false,at:now.addingTimeInterval(136))
  check(finalPartial.observations.first?.dashboard(entries:[],now:now.addingTimeInterval(136)).isDetectedActiveRender==true && finalPartial.observations.first?.completed==nil,"partial final snapshot hides positive task or attributes counter")
  finalPartialReader.snapshots=[];finalPartialReader.finalPartial=false
  let partialGone=await finalPartialDiscovery.collect(store:store,links:[:],writable:false,at:now.addingTimeInterval(139))
  check(partialGone.historyObservations.isEmpty,"incomplete exclusivity seeded a terminal claim")
  let exitReader=SnapshotFeed([snapshot]);let exitDiscovery=NativeRenderDiscovery(reader:exitReader,scripts:scripts)
  let beforeExit=await exitDiscovery.collect(store:store,links:[:],writable:false,at:now.addingTimeInterval(140))
  check(beforeExit.observations.first?.completed==nil && beforeExit.observations.first?.dashboard(entries:[],now:now.addingTimeInterval(140)).isDetectedActiveRender==true,"new scope borrows terminal count before its first reading")
  exitReader.snapshots=[]
  let afterExit=await exitDiscovery.collect(store:store,links:[:],writable:false,at:now.addingTimeInterval(143))
  check(afterExit.observations.isEmpty,"exited identity remains actionable/current")
  check(afterExit.historyObservations.first?.dashboard(entries:[],now:now.addingTimeInterval(143)).isFinishedRender==true,"final PNG stability after process exit never reaches technical finished")
  check(afterExit.historyObservations.first?.dashboard(entries:[],now:now.addingTimeInterval(143)).isDetectedActiveRender==false,"post-exit reconciliation invents an active task")
  let settled=await exitDiscovery.collect(store:store,links:[:],writable:false,at:now.addingTimeInterval(146))
  check(settled.historyObservations.isEmpty,"terminal reconciliation became a permanent poller")
  try await checkCatalogue(root:root,active:a.dashboard(entries:[],now:now),terminal:terminalJob)
  check(!FileManager.default.fileExists(atPath:store.root.appendingPathComponent("config.json").path),"automatic adapter creates manual config")
  print("NativeScriptIntegrationTests: \(checks) assertions PASS; synthetic existing files/processes only, no SSH/UI/AppSupport/producer execution")
 }
}
