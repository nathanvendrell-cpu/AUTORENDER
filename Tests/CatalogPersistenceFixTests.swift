import Foundation
final class FixturePersistenceHook {
 enum Mode {case none,typedCancellation,ioAndCancelledTask}
 static let lock=NSLock();static var mode=Mode.none
 static func arm(_ value:Mode){lock.lock();mode=value;lock.unlock()}
 static func check() throws {
  lock.lock();let value=mode;mode = .none;lock.unlock()
  switch value {
  case .none:return
  case .typedCancellation:throw CancellationError()
  case .ioAndCancelledTask:
   withUnsafeCurrentTask{$0?.cancel()}
   throw NSError(domain:NSCocoaErrorDomain,code:NSFileWriteNoPermissionError)
  }
 }
}
@main enum PersistenceFixTests {
 static var checks=0
 static func require(_ value:Bool,_ message:String){checks+=1;precondition(value,message)}
 static func input(_ jobs:[RenderDashboardJob]=[])->RenderCatalogInput {
  var result=RenderCatalogInput(revision:1,macJobs:[],shadow:nil,declaration:nil,config:AppConfig(),knownFolders:[:],entries:[],macEntries:[],folderEntries:[],shadowEntries:[],shadowFolderEntries:[],macHealth:SourceHealth(),shadowHealth:SourceHealth(),folderHealth:SourceHealth(),remoteHealth:SourceHealth())
  result.preparedJobs=jobs;return result
 }
 static func job(_ median:Double?)->RenderDashboardJob {
  RenderDashboardJob(id:"fixture",title:"fixture",projectID:"fixture",source:.macMonitor,workType:.video,rawCount:nil,postCount:nil,rawProgress:nil,postProgress:nil,totalProvenance:nil,activity:.unknown,isFresh:false,observedAt:Date(timeIntervalSince1970:1),lastActivity:nil,historicalMedianSeconds:median,sampledOutputsLastHour:nil,eta:nil,process:nil,gpu:nil,gpuRaw:nil,plans:[],tasks:[],stageDescription:nil,previewEntries:[])
 }
 static func main() async throws {
  let temporary=URL(fileURLWithPath:CommandLine.arguments[1])
  let cancelRoot=temporary.appendingPathComponent("typed-cancel")
  let cancelledService=RenderCatalogService(root:cancelRoot)
  FixturePersistenceHook.arm(.typedCancellation)
  let cancelled=await cancelledService.build(input())
  require(cancelled==nil,"typed cancellation returns a false-error snapshot")
  require(!FileManager.default.fileExists(atPath:cancelRoot.appendingPathComponent("jobs.json").path),"cancelled build wrote catalogue")
  require(await cancelledService.catalogueWriteCount==0,"cancelled build counted a write")
  let next=await cancelledService.build(input())!
  require(next.persistenceIssue==nil,"typed cancellation left sticky error")
  require(await cancelledService.catalogueWriteCount==1,"fresh build after cancellation cannot save")
  let mixedRoot=temporary.appendingPathComponent("real-io-with-cancel")
  let mixed=RenderCatalogService(root:mixedRoot)
  FixturePersistenceHook.arm(.ioAndCancelledTask)
  let task=Task{await mixed.build(input())}
  let actualIO=await task.value
  require(actualIO?.persistenceIssue != nil,"blanket cancellation hid actual IO error")
  require(!FileManager.default.fileExists(atPath:mixedRoot.appendingPathComponent("jobs.json").path),"failed actual IO counted as save")
  let mixedRecovered=await mixed.build(input())!
  require(mixedRecovered.persistenceIssue==nil,"successful save did not clear actual IO error")
  let ioRoot=temporary.appendingPathComponent("blocked-root")
  try Data("own temporary blocking file".utf8).write(to:ioRoot)
  let io=RenderCatalogService(root:ioRoot)
  let initial=await io.build(input())!
  require(initial.persistenceIssue != nil,"real filesystem failure not reported")
  require(await io.catalogueWriteCount==0,"real filesystem failure counted a save")
  try FileManager.default.moveItem(at:ioRoot,to:temporary.appendingPathComponent("preserved-blocking-file"))
  try FileManager.default.createDirectory(at:ioRoot,withIntermediateDirectories:true)
  let recovered=await io.build(input())!
  require(recovered.persistenceIssue==nil,"warning remains after successful recovery write")
  let bytes=try Data(contentsOf:ioRoot.appendingPathComponent("jobs.json"))
  let decoded=try JSONDecoder().decode(RenderJobCatalogue.self,from:bytes)
  let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
  require(try encoder.encode(decoded)==bytes,"durable recovery bytes differ from typed re-encoding")
  require(await io.catalogueWriteCount==1,"successful recovery not recorded")
  let encodingRoot=temporary.appendingPathComponent("encoding-failure")
  let encoding=RenderCatalogService(root:encodingRoot)
  let failedEncode=await encoding.build(input([job(.infinity)]))!
  require(failedEncode.persistenceIssue != nil,"nonfinite encoding error hidden")
  require(!FileManager.default.fileExists(atPath:encodingRoot.appendingPathComponent("jobs.json").path),"encoding failure wrote partial file")
  let encodeRecovered=await encoding.build(input([job(1)]))!
  require(encodeRecovered.persistenceIssue==nil,"successful encoding recovery did not clear warning")
  let decodedRecovery=try JSONDecoder().decode(RenderJobCatalogue.self,from:Data(contentsOf:encodingRoot.appendingPathComponent("jobs.json")))
  require(decodedRecovery.records["fixture"]?.job.historicalMedianSeconds==1,"recovery changed intended record")
  for (name,content) in [("future-schema","{\"schemaVersion\":99,\"revision\":1,\"records\":{}}"),("malformed","{broken")]{
   let root=temporary.appendingPathComponent(name);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
   let file=root.appendingPathComponent("jobs.json");let original=Data(content.utf8);try original.write(to:file)
   let protected=RenderCatalogService(root:root);let snapshot=await protected.build(input())!
   require(snapshot.persistenceIssue != nil,"future/malformed catalogue warning cleared")
   require(try Data(contentsOf:file)==original,"future/malformed catalogue overwritten")
   require(await protected.catalogueWriteCount==0,"future/malformed catalogue admitted a write")
  }
  let result:[String:Any]=["assertions":checks,"result":"PASS","typedCancellationNoWarningNoWrite":true,"actualIOWhileCancelledStillReported":true,"actualIOAndEncodingRecovery":true,"exactTypedDurableReread":true,"futureAndMalformedCataloguePreserved":true,"productionMutation":false,"runtimeInitialErrorProven":false,"fixtureInstrumentation":"test-only deterministic pre-write boundary; no production hook added"]
  FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:result,options:.sortedKeys))
 }
}
