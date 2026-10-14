import Foundation
struct CheckFailure:Error {let message:String}
actor Feed {
 var blobs:[Data];var calls=0
 init(_ items:[Data]){blobs=items}
 func next()->Data? {calls+=1;return blobs.isEmpty ? nil : blobs.removeFirst()}
}
actor Gate {
 var continuation:CheckedContinuation<Void,Never>?
 var begun=false;var calls=0
 func wait() async {calls+=1;begun=true;await withCheckedContinuation {continuation=$0}}
 func release(){continuation?.resume();continuation=nil}
}
@main enum ShadowRunDiscoveryTests {
 static var checks=0
 static func check(_ ok:Bool,_ message:String)throws {checks+=1;if !ok {throw CheckFailure(message:message)}}
 @MainActor static func main() async throws {
  let bytes=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]));let sourceBytes=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[2]));let sources=try JSONDecoder().decode([ShadowDeclaredSource].self,from:sourceBytes)
  let envelope=try JSONDecoder().decode(ShadowRunEnvelope.self,from:bytes);let run=envelope.runs[0]
  try check(run.validated(),"neutral observed source rejected")
  let job=run.dashboard(fresh:true)
  try check(job.source == .shadowMonitor && job.id.hasPrefix("shadow:"),"new source breaks archive key schema/UI labels")
  try check(job.rawCount==5 && job.postCount==3 && job.rawProgress?.total==6 && job.postProgress?.total==6,"raw/post stages merged")
  try check(job.versionLabel==job.title && job.versionLabel != "Source déclarée","actual version label lost")
  try check(job.activity == .resumeRequired && job.eta==nil,"dated memory/incomplete state dishonest")
  try check(run.dashboard(fresh:false).activity == .unknown && !run.dashboard(fresh:false).isFresh,"cached record promoted live")
  func modified(_ body:Data,_ transform:(inout [String:Any])->Void)throws->Data {var object=try JSONSerialization.jsonObject(with:body) as! [String:Any];transform(&object);return try JSONSerialization.data(withJSONObject:object)}
  let wrongPlans=try modified(bytes){object in var runs=object["runs"] as! [[String:Any]];var counts=runs[0]["planCounts"] as! [String:Any];counts["unknownPlan"]=["raw":0,"post":0];runs[0]["planCounts"]=counts;object["runs"]=runs}
  try check(!(try JSONDecoder().decode(ShadowRunEnvelope.self,from:wrongPlans)).runs[0].validated(),"extra planCounts key accepted")
  let missingWrong=try modified(bytes){object in var runs=object["runs"] as! [[String:Any]];runs[0]["missingRaw"]=["X_9999.png"];object["runs"]=runs}
  try check(!(try JSONDecoder().decode(ShadowRunEnvelope.self,from:missingWrong)).runs[0].validated(),"foreign frame missing ID accepted")
  let terminalBytes=try modified(bytes){object in
   var runs=object["runs"] as! [[String:Any]];runs[0]["activity"]="countsReached";runs[0]["rawCount"]=6;runs[0]["postCount"]=6;runs[0]["missingRaw"]=[];runs[0]["missingPost"]=[];runs[0]["planCounts"]=["A":["raw":3,"post":3],"B":["raw":3,"post":3]];object["runs"]=runs
  }
  let terminal=try JSONDecoder().decode(ShadowRunEnvelope.self,from:terminalBytes).runs[0]
  try check(terminal.validated() && terminal.dashboard(fresh:true).canArchive,"fully counted declared stages cannot archive")
  let badTerminal=try modified(terminalBytes){object in var runs=object["runs"] as! [[String:Any]];runs[0]["processCoverage"]=false;object["runs"]=runs}
  try check(!(try JSONDecoder().decode(ShadowRunEnvelope.self,from:badTerminal)).runs[0].validated(),"partial terminal accepted")
  let root=FileManager.default.temporaryDirectory.appendingPathComponent("autoren-shadow-discovery-tests-"+UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer {try? FileManager.default.removeItem(at:root)}
  let positivePartial=try modified(bytes){object in
   object["partial"]=true;var rows=object["runs"] as! [[String:Any]];rows[0]["processCoverage"]=false;rows[0]["activity"]="running";rows[0]["provenance"]="process_observed";rows[0]["claims"]=[["pid":42,"birth":object["observedAt"]!,"phase":"raw","plan":"A","context":String(repeating:"e",count:64),"binding":["engine":"blender","ownerVerified":true,"scriptPath":sources[0].scriptPath,"scriptSHA256":run.scriptHash,"outputRoot":sources[0].rawRoot]]];rows[0]["phases"]=["raw"];object["runs"]=rows
  }
  let partialRun=try JSONDecoder().decode(ShadowRunEnvelope.self,from:positivePartial).runs[0]
  try check(partialRun.validated() && !partialRun.processCoverage,"qualified partial claim rejected")
  try check(partialRun.dashboard(fresh:true).activity == .running,"partial coverage hides observed worker")
  try check(partialRun.dashboard(fresh:false).activity == .unknown,"partial cached claim promoted live")
  let partialRoot=root.appendingPathComponent("partial-positive");let partialObserver=ShadowRunDiscovery(root:partialRoot,loader:{_ in positivePartial})
  await partialObserver.refresh(sources,force:true)
  try check(partialObserver.jobs.first?.activity == .running && partialObserver.health.partial && !partialObserver.health.isStale,"consumer loses positive partial worker")
  let noBinding=try modified(positivePartial){object in var rows=object["runs"] as! [[String:Any]];var claims=rows[0]["claims"] as! [[String:Any]];claims[0].removeValue(forKey:"binding");rows[0]["claims"]=claims;object["runs"]=rows}
  let proofReject=ShadowRunDiscovery(root:partialRoot,loader:{_ in noBinding});await proofReject.refresh(sources,force:true)
  try check(proofReject.health.isStale && proofReject.jobs.first?.activity == .unknown,"fresh declared claim without qualified proof accepted");proofReject.stop()
  partialObserver.stop();await partialObserver.waitForShutdown()
  let missingSource=try modified(bytes){$0["runs"]=[]}
  let staleRun=try modified(bytes){object in var runs=object["runs"] as! [[String:Any]];runs[0]["observedAt"]="2001-01-01T00:00:00Z";object["runs"]=runs}
  let inconsistentCoverage=try modified(bytes){$0["partial"]=true}
  let feed=Feed([bytes,missingSource,bytes,staleRun,bytes,inconsistentCoverage,bytes,Data("{broken".utf8)])
  let observer=ShadowRunDiscovery(root:root,loader:{_ in await feed.next()})
  for index in 0..<8 {
   await observer.refresh(sources,force:true)
   try check(observer.jobs.first?.rawCount==5 && observer.jobs.first?.postCount==3,"rejected payload changes counts")
   if index%2==1 {try check(observer.health.isStale && observer.jobs.allSatisfy{!$0.isFresh && $0.activity != .running},"rejected payload retains fresh claims")}
  }
  let cacheURL=root.appendingPathComponent("shadow-runs-last-good.json");let cache=try Data(contentsOf:cacheURL);try check((try JSONDecoder().decode(ShadowRunEnvelope.self,from:cache)).runs.count==1,"bad snapshot overwrites cache")
  let foreign=try modified(bytes){object in var rows=object["runs"] as! [[String:Any]];rows[0]["scriptHash"]=String(repeating:"d",count:64);object["runs"]=rows}
  let discord=ShadowRunDiscovery(root:root,loader:{_ in foreign});await discord.refresh(sources,force:true)
  try check(discord.health.isStale && discord.jobs.first?.rawCount == 5,"foreign hash replaced valid cache")
  try check(try Data(contentsOf:cacheURL) == cache,"foreign snapshot wrote cache")
  discord.stop()
  var otherSources=sources;otherSources[0].rawRoot="C:\\foreign\\raw";otherSources[0].postRoot="C:\\foreign\\post";otherSources[0].outputRoot="C:\\foreign"
  let foreignReload=ShadowRunDiscovery(root:root,loader:{_ in nil});await foreignReload.loadLastGood(otherSources)
  try check(foreignReload.jobs.isEmpty,"mismatched roots accepted on reload");foreignReload.stop()
  var altered=sources[0];altered.plans=["A":[1,2],"B":[3,6]]
  try check(!(try JSONDecoder().decode(ShadowRunEnvelope.self,from:bytes)).runs[0].matches(altered),"changed plans accepted")
  observer.stop();await observer.waitForShutdown()
  let restored=ShadowRunDiscovery(root:root,loader:{_ in nil});await restored.loadLastGood(sources);try check(restored.jobs.count==1 && restored.jobs[0].activity == .unknown && !restored.jobs[0].isFresh,"cache not restored without network or promoted active")
  restored.stop()
  let blocked=Gate();let lateRoot=root.appendingPathComponent("late");let late=ShadowRunDiscovery(root:lateRoot,loader:{_ in await blocked.wait();return bytes})
  let pending=Task {await late.refresh(sources,force:true)}
  for _ in 0..<100 {if await blocked.begun {break};try await Task.sleep(for:.milliseconds(2))}
  late.stop();await blocked.release();await pending.value
  try check(late.jobs.isEmpty && !FileManager.default.fileExists(atPath:lateRoot.appendingPathComponent("shadow-runs-last-good.json").path),"late after stop publishes/cache writes")
  let coalesced=Gate();let latest=Feed([bytes]);let serial=ShadowRunDiscovery(root:root.appendingPathComponent("coalesced"),loader:{_ in
   let calls=await coalesced.calls
   if calls==0 {await coalesced.wait();return bytes}
   return await latest.next()
  })
  let first=Task {await serial.refresh(sources,force:true)}
  for _ in 0..<100 {if await coalesced.begun {break};try await Task.sleep(for:.milliseconds(2))}
  await serial.refresh(sources,force:true);await serial.refresh(sources,force:true)
  await coalesced.release();await first.value
  let firstCalls=await coalesced.calls;let followCalls=await latest.calls
  try check(firstCalls==1 && followCalls==1,"concurrent manual requests not coalesced")
  try check(serial.jobs.count==1,"latest coalesced result absent")
  serial.stop()
  var original=AppConfig(jobArchives:["mac:preserved":Date(timeIntervalSince1970:12345)]);original.shadowRunSources=sources
  let prefs=try JSONEncoder().encode(original);let roundtrip=try JSONDecoder().decode(AppConfig.self,from:prefs)
  try check(roundtrip.shadowRunSources==sources && roundtrip.jobArchives==original.jobArchives,"new source config loses archive dates")
  var second=job;second.id="shadow:run:"+String(repeating:"d",count:64);second.versionID=String(repeating:"d",count:64)
  func catalogueInput(_ config:AppConfig)->RenderCatalogInput {var v=RenderCatalogInput(revision:1,macJobs:[],shadow:nil,declaration:nil,config:config,knownFolders:[:],entries:[],macEntries:[],folderEntries:[],shadowEntries:[],shadowFolderEntries:[],macHealth:SourceHealth(),shadowHealth:SourceHealth(),folderHealth:SourceHealth(),remoteHealth:SourceHealth());v.preparedJobs=[job,second];return v}
  let catalogue=RenderCatalogService(root:root.appendingPathComponent("business"))
  let isolated=await catalogue.build(catalogueInput(AppConfig()))!
  try check(isolated.works.count==2 && job.sourceWorkID==nil && job.sourceVersionID==nil,"technical scope forces business work or auto-merges names")
  var chosen=AppConfig();for entry in [job,second] {chosen.jobContexts[entry.id]=RenderJobContext(projectID:job.projectID,workID:"chosen-work",versionID:nil,workTitle:"Human chosen work",versionLabel:nil)}
  let grouped=await catalogue.build(catalogueInput(chosen))!
  try check(grouped.works.count==1 && grouped.works[0].jobs.count==2 && Set(grouped.jobs.map(\.id))==[job.id,second.id],"user cannot group two technical versions without changing IDs")
  let actorSeries=RenderCatalogService(root:root.appendingPathComponent("worker-series"))
  for index in 0..<4 {
   let sampleData=try modified(bytes){object in var rows=object["runs"] as! [[String:Any]];rows[0]["activity"]=index==3 ? "unknown" : "running";rows[0]["provenance"]=index==3 ? "source_declared" : "process_observed";rows[0]["claims"]=index==3 ? [] : [["pid":index+1,"birth":object["observedAt"]!,"phase":index==2 ? "post" : "raw","plan":"A","context":String(repeating:"e",count:64)]];object["runs"]=rows}
   let sample=try JSONDecoder().decode(ShadowRunEnvelope.self,from:sampleData).runs[0].dashboard(fresh:true)
   var v=catalogueInput(AppConfig());v.preparedJobs=[sample]
   let snapshot=await actorSeries.build(v)!
   try check(snapshot.knownJobCount==1 && snapshot.jobs[0].rawCount==5 && snapshot.jobs[0].postCount==3,"ephemeral worker phase creates extra catalogue jobs or merged counts")
  }
  let bootstrap=try JSONDecoder().decode(ShadowRunEnvelope.self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[3])))
  try check(bootstrap.runs.allSatisfy{$0.validated()},"ROOT real snapshot bootstrap invalid")
  try check(bootstrap.runs.allSatisfy{$0.dashboard(fresh:false).activity == .unknown && !$0.dashboard(fresh:false).isFresh && $0.dashboard(fresh:false).eta==nil},"ROOT dated cache promoted to current activity")
  if CommandLine.arguments.count>4 {
   let delta=try JSONDecoder().decode(AppConfig.self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[4])))
   try check(bootstrap.runs.count == delta.shadowRunSources.count && bootstrap.runs.allSatisfy{run in delta.shadowRunSources.contains{run.matches($0)}},"real bootstrap does not match declared scope")
  }
  var scriptChanged=sources[0];scriptChanged.scriptPath="C:\\different\\script.py"
  try check(!run.matches(scriptChanged),"different declared script path accepted")
  let automatic=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[5]));let automatic2=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[6]))
  let autoRoot=root.appendingPathComponent("automatic");let autoFeed=Feed([automatic,automatic2,automatic])
  let autoDiscovery=ShadowRunDiscovery(root:autoRoot,loader:{_ in await autoFeed.next()})
  await autoDiscovery.refresh([],force:true)
  try check(autoDiscovery.jobs.count==1 && autoDiscovery.jobs[0].activity == .running,"supported automatic source requires manual declaration")
  let autoID=autoDiscovery.jobs[0].id
  await autoDiscovery.refresh([],force:true)
  try check(autoDiscovery.jobs.count==2 && autoDiscovery.jobs.filter(\.isFresh).count==1 && autoDiscovery.jobs.first(where:{$0.id==autoID})?.activity == .unknown,"new automatic source loses history/promotes old worker")
  let autoIDs=Set(autoDiscovery.jobs.map(\.id))
  await autoDiscovery.refresh([],force:true)
  try check(Set(autoDiscovery.jobs.map(\.id)) == autoIDs && autoDiscovery.jobs.first(where:{$0.id==autoID})?.activity == .running,"automatic jobs unstable on worker re-observation")
  autoDiscovery.stop();await autoDiscovery.waitForShutdown()
  let autoRestore=ShadowRunDiscovery(root:autoRoot,loader:{_ in nil});await autoRestore.loadLastGood([])
  try check(Set(autoRestore.jobs.map(\.id))==autoIDs && autoRestore.jobs.allSatisfy{!$0.isFresh && $0.activity == .unknown},"automatic cache attestation/history not restored stale")
  autoRestore.stop()
  let autoCacheURL=autoRoot.appendingPathComponent("shadow-runs-last-good.json");let autoCacheBytes=try Data(contentsOf:autoCacheURL)
  for field in ["rawRoot","scriptPath","expectedScriptSHA256"] {
   let bad=try modified(automatic){object in var autos=object["automaticSources"] as! [[String:Any]];var descriptor=autos[0]["source"] as! [String:Any];descriptor[field]=field == "expectedScriptSHA256" ? String(repeating:"d",count:64) : "C:\\foreign\\scope";autos[0]["source"]=descriptor;object["automaticSources"]=autos}
   let rejected=ShadowRunDiscovery(root:autoRoot,loader:{_ in bad});await rejected.refresh([],force:true)
   try check(rejected.health.isStale && Set(rejected.jobs.map(\.id))==autoIDs,"foreign automatic descriptor accepted")
   try check(try Data(contentsOf:autoCacheURL)==autoCacheBytes,"bad automatic descriptor wrote cache");rejected.stop()
  }
  let badClaim=try modified(automatic){object in var autos=object["automaticSources"] as! [[String:Any]];var claims=autos[0]["claims"] as! [[String:Any]];claims[0]["pid"]=999;autos[0]["claims"]=claims;object["automaticSources"]=autos}
  let claimReject=ShadowRunDiscovery(root:autoRoot,loader:{_ in badClaim});await claimReject.refresh([],force:true);try check(claimReject.health.isStale,"mismatched automatic claim accepted");claimReject.stop()
  for field in ["engine","ownerVerified","scriptPath","scriptSHA256","outputRoot"] {
   let bad=try modified(automatic){object in
    var rows=object["runs"] as! [[String:Any]];var claims=rows[0]["claims"] as! [[String:Any]];var binding=claims[0]["binding"] as! [String:Any]
    binding[field]=field == "ownerVerified" ? false : (field == "engine" ? "powershell" : "foreign")
    claims[0]["binding"]=binding;rows[0]["claims"]=claims;object["runs"]=rows
    var autos=object["automaticSources"] as! [[String:Any]];autos[0]["claims"]=claims;object["automaticSources"]=autos
   }
   let reject=ShadowRunDiscovery(root:autoRoot,loader:{_ in bad});await reject.refresh([],force:true)
   try check(reject.health.isStale && Set(reject.jobs.map(\.id))==autoIDs,"invalid engine/owner/script/output claim binding accepted");reject.stop()
  }
  let autoEnvelope=try JSONDecoder().decode(ShadowRunEnvelope.self,from:automatic);var current=autoEnvelope.automaticSources![0].source;current.rawRoot="C:\\foreign\\raw"
  let priority=ShadowRunDiscovery(root:root.appendingPathComponent("declaration-priority"),loader:{_ in automatic});await priority.refresh([current],force:true)
  try check(priority.jobs.isEmpty && priority.health.isStale,"auto descriptor bypassed mismatched known declaration");priority.stop()
  let connectionRoot=root.appendingPathComponent("connection-gate");try FileManager.default.createDirectory(at:connectionRoot,withIntermediateDirectories:true)
  let connectionDiscovery=ShadowRunDiscovery(root:connectionRoot,loader:{_ in nil})
  try check(!(await connectionDiscovery.hasConfiguredConnection()),"missing connection enables automatic polling")
  try Data("{\"host\":\"fixture\",\"user\":\"fixture\",\"identityFile\":\"/fixture-key\"}".utf8).write(to:connectionRoot.appendingPathComponent("connection.json"))
  try check(!(await connectionDiscovery.hasConfiguredConnection()),"missing key enables automatic polling")
  let keyFile=connectionRoot.appendingPathComponent("fixture-key");try Data("fixture".utf8).write(to:keyFile)
  let connectionBytes=try JSONSerialization.data(withJSONObject:["host":"fixture","user":"fixture","identityFile":keyFile.path]);try connectionBytes.write(to:connectionRoot.appendingPathComponent("connection.json"))
  try check(await connectionDiscovery.hasConfiguredConnection(),"configured connection cannot enable declaration-free polling");connectionDiscovery.stop()
  print("ShadowRunDiscoveryTests: \(checks) assertions PASS; neutral fixtures, no live process/network/AppSupport")
 }
}
