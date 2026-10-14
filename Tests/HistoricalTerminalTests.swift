import Foundation
@main enum HistoricalTerminalTests {
 static var checks=0
 static func check(_ value:Bool,_ message:String){checks+=1;precondition(value,message)}
 static func mutate(_ original:Data,_ action:(inout [String:Any])->Void) throws -> ShadowObservedRun {
  var object=try JSONSerialization.jsonObject(with:original) as! [String:Any];action(&object)
  return try JSONDecoder().decode(ShadowObservedRun.self,from:JSONSerialization.data(withJSONObject:object))
 }
 static func input(_ jobs:[RenderDashboardJob],config:AppConfig=AppConfig())->RenderCatalogInput {
  var result=RenderCatalogInput(revision:1,macJobs:[],shadow:nil,declaration:nil,config:config,knownFolders:[:],entries:[],macEntries:[],folderEntries:[],shadowEntries:[],shadowFolderEntries:[],macHealth:SourceHealth(),shadowHealth:SourceHealth(),folderHealth:SourceHealth(),remoteHealth:SourceHealth())
  result.preparedJobs=jobs;return result
 }
 static func main() async throws {
  let bytes=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]));let root=URL(fileURLWithPath:CommandLine.arguments[2]);let run=try JSONDecoder().decode(ShadowObservedRun.self,from:bytes)
  check(run.validated(),"neutral terminal invalid")
  let cached=run.dashboard(fresh:false)
  check(cached.activity == .countsReached && cached.isTerminalCounted,"stale prequalified terminal lost")
  check(cached.isFinishedRender,"terminal section unavailable")
  check(!cached.isFresh && cached.retainedHistorical,"cached terminal promoted fresh")
  check(!cached.isDetectedActiveRender && cached.taskQualification==nil,"cached terminal promoted active")
  check(cached.rawProgress?.completed==6 && cached.postProgress?.completed==6,"raw/post stages merged")
  let unknown=try mutate(bytes){$0["activity"]="unknown"}
  check(unknown.validated(),"unknown complete counters fixture invalid")
  check(!unknown.dashboard(fresh:false).isFinishedRender,"complete declared counters alone promoted terminal")
  let partial=try mutate(bytes){$0["processCoverage"]=false}
  check(!partial.validated() && !partial.dashboard(fresh:false).isFinishedRender,"partial terminal promoted")
  let missing=try mutate(bytes){$0["missingPost"]=["B_0006.png"]}
  check(!missing.validated() && !missing.dashboard(fresh:false).isFinishedRender,"missing terminal promoted")
  let inconsistent=try mutate(bytes){$0["rawCount"]=5}
  check(!inconsistent.validated() && !inconsistent.dashboard(fresh:false).isFinishedRender,"inconsistent raw count promoted")
  let badProvenance=try mutate(bytes){$0["provenance"]="legacy_unqualified"}
  check(!badProvenance.validated() && !badProvenance.dashboard(fresh:false).isFinishedRender,"unqualified provenance promoted")
  let wrongIdentity=try mutate(bytes){$0["id"]="shadow:run:"+String(repeating:"f",count:64)}
  check(!wrongIdentity.validated() && !wrongIdentity.dashboard(fresh:false).isFinishedRender,"incoherent identity promoted")
  check(!cached.canArchive,"historical row gained a fresh archive operation")
  let claims:[[String:Any]]=[["pid":42,"birth":"2026-10-13T23:59:00Z","phase":"raw","plan":"A","context":String(repeating:"e",count:64),"binding":["engine":"blender","ownerVerified":true,"scriptPath":"C:\\neutral\\driver.py","scriptSHA256":run.scriptHash,"outputRoot":run.rawRoot]]]
  let claimed=try mutate(bytes){$0["claims"]=claims}
  check(!claimed.validated() && !claimed.dashboard(fresh:false).isFinishedRender,"terminal with active claims promoted")
  let active=try mutate(bytes){$0["activity"]="running";$0["provenance"]="process_observed";$0["claims"]=claims;$0["phases"]=["raw"]}
  check(active.validated(),"fresh qualified worker fixture invalid")
  check(!active.dashboard(fresh:false).isDetectedActiveRender && !active.dashboard(fresh:false).isFinishedRender,"stale running promoted")
  let live=active.dashboard(fresh:true);check(live.isDetectedActiveRender && !live.isFinishedRender,"fresh qualified source not active")
  let catalogue=RenderCatalogService(root:root.appendingPathComponent("fixture-catalogue"))
  _=await catalogue.build(input([run.dashboard(fresh:true)]))
  let offline=await catalogue.build(input([cached]))!
  check(offline.jobs.first?.isFinishedRender==true && offline.jobs.first?.retainedHistorical==true,"same-ID catalogue overwrites known terminal")
  let reloaded=RenderCatalogService(root:root.appendingPathComponent("fixture-catalogue"));let durable=await reloaded.build(input([]))!
  check(durable.jobs.first?.isFinishedRender==true && durable.jobs.first?.retainedHistorical==true,"terminal lost after durable reload")
  let restarted=await catalogue.build(input([live]))!
  check(restarted.jobs.first?.isDetectedActiveRender==true && restarted.jobs.first?.isFinishedRender==false,"fresh source cannot supersede old terminal")
  var config=AppConfig();let archive=Date(timeIntervalSince1970:1);config.jobArchives[cached.id]=archive
  let archived=await catalogue.build(input([cached],config:config))!
  check(archived.jobs.first?.archivedAt==archive && archived.reactivatedArchiveIDs.isEmpty,"cached terminal changed archive preference")
  var masked=cached;masked.archivedAt=archive
  check(!masked.isFinishedRender && masked.isTerminalCounted,"archive projection broken")
  let result:[String:Any]=["assertions":checks,"result":"PASS","cachedValidatedTerminalPreserved":true,"noCounterOnlyPromotion":true,"noFalseActive":true,"freshQualifiedSupersedes":true,"durableCatalogueReload":true,"archivePreferencePreserved":true,"realDataModified":false]
  FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:result,options:.sortedKeys))
 }
}
