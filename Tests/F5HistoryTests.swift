import Foundation
import CryptoKit
actor Freshness {var count=0;func valid()->Bool {count+=1;return count==1}}
@main enum F5HistoryTests {
 static var checks=0
 static func check(_ condition:Bool,_ message:String){checks+=1;precondition(condition,message)}
 static func entries(_ prefix:String,_ count:Int,_ pathSize:Int=0)->[RenderEntry] {
  (0..<count).map {i in RenderEntry(id:"\(prefix)-\(i)",source:.macFolder,job:prefix,filename:"\(i).png",modified:Date(timeIntervalSince1970:Double(i)),state:.stable,path:pathSize>0 ? String(repeating:"x",count:pathSize)+"\(i)" : "/SIMULATED/\(prefix)/\(i).png",previewURL:nil)}
 }
 static func historyURL(_ root:URL,_ id:String)->URL {root.appendingPathComponent("Outputs/"+SHA256.hash(data:Data(id.utf8)).map {String(format:"%02x",$0)}.joined()+".json")}
 static func budgets(_ service:RenderCatalogService) async {
  let s=await service.historyCacheStats();check(s.scopes<=4 && s.entries<=10000 && s.chargeBytes<=8*1024*1024,"cache budget exceeded")
 }
 @MainActor static func wait(_ controller:HistoryController) async throws {
  for _ in 0..<1000 {if !controller.loading{return};try await Task.sleep(for:.milliseconds(1))}
  preconditionFailure("controller load did not finish")
 }
 @MainActor static func main() async throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent("autoren-f5-tests-"+UUID().uuidString)
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
  defer {try? FileManager.default.removeItem(at:root)}
  let service=RenderCatalogService(root:root.appendingPathComponent("lru"))
  var first:RenderHistoryPage?
  for j in 0..<4 {
   let page=await service.history(jobID:"j\(j)",incoming:entries("j\(j)",200),cursor:nil,limit:40,coverage:"fixture",scope:"scope")
   if j==0 {first=page};await budgets(service)
  }
  _=await service.history(jobID:"j0",incoming:[],cursor:first!.nextCursor,limit:40,coverage:"fixture",scope:"scope")
  _=await service.history(jobID:"j4",incoming:entries("j4",200),cursor:nil,limit:40,coverage:"fixture",scope:"scope")
  var stats=await service.historyCacheStats();check(stats.jobIDs.contains("j0") && !stats.jobIDs.contains("j1"),"LRU did not preserve touched scope")
  let before=await service.historyWriteCount
  let restored=await service.history(jobID:"j1",incoming:[],cursor:nil,limit:40,coverage:"fixture",scope:"scope")
  check(restored.entries.first?.id=="j1-199" && restored.totalKnown==200,"evicted scope lost persisted rows")
  check(await service.historyWriteCount==before,"rehydration rewrote durable JSON");await budgets(service)
  let entryBudget=RenderCatalogService(root:root.appendingPathComponent("entry-budget"))
  for j in 0..<2 {_=await entryBudget.history(jobID:"large\(j)",incoming:entries("large\(j)",6000),cursor:nil,limit:40,coverage:"fixture",scope:"scope");await budgets(entryBudget)}
  stats=await entryBudget.historyCacheStats();check(stats.scopes==1 && stats.entries==6000,"entry budget failed to evict before scope limit")
  let oversized=await entryBudget.history(jobID:"oversized",incoming:entries("oversized",10001),cursor:nil,limit:40,coverage:"fixture",scope:"scope")
  stats=await entryBudget.historyCacheStats();check(!stats.jobIDs.contains("oversized"),"oversized entry set admitted")
  let next=await entryBudget.history(jobID:"oversized",incoming:[],cursor:oversized.nextCursor,limit:40,coverage:"fixture",scope:"scope")
  check(next.entries.first?.id=="oversized-9960" && next.totalKnown==10001,"oversized cursor cannot rehydrate")
  let byteService=RenderCatalogService(root:root.appendingPathComponent("bytes"))
  let bytePage=await byteService.history(jobID:"bytes",incoming:entries("bytes",1000,9000),cursor:nil,limit:40,coverage:"fixture",scope:"scope")
  check(bytePage.totalKnown==1000 && bytePage.persistenceError==nil,"oversized byte payload not durable")
  check(await byteService.historyCacheStats().scopes==0,"byte budget not enforced");await budgets(byteService)
  // Walk all rows forward, then back with no stored cursor stack; repeatedly force LRU eviction.
  let walk=RenderCatalogService(root:root.appendingPathComponent("walk"));let all=entries("walk",237)
  var page=await walk.history(jobID:"walk",incoming:all,cursor:nil,limit:40,coverage:"fixture",scope:"scope")
  var seen=page.entries.map(\.id);var pages=1
  while let cursor=page.nextCursor {
   for j in 0..<5 {_=await walk.history(jobID:"other\(j)",incoming:entries("other\(j)",2),cursor:nil,limit:40,coverage:"fixture",scope:"scope")}
   page=await walk.history(jobID:"walk",incoming:[],cursor:cursor,limit:40,coverage:"fixture",scope:"scope")
   seen += page.entries.map(\.id);pages+=1;await budgets(walk)
  }
  check(seen==all.reversed().map(\.id),"forward traversal contains holes or duplicates")
  while let cursor=page.previousCursor {page=await walk.history(jobID:"walk",incoming:[],cursor:cursor,limit:40,coverage:"fixture",scope:"scope");pages-=1}
  check(pages==1 && page.entries.map(\.id)==Array(all.reversed().prefix(40)).map(\.id),"previous traversal cannot reach first page")
  let stale=await walk.history(jobID:"walk",incoming:[],cursor:page.nextCursor,limit:40,coverage:"fixture",scope:"changed")
  check(stale.entries.isEmpty && stale.nextCursor==nil,"stale scope cursor accepted")
  // Corrupt existing file stays intact and is never admitted or presented as saved.
  let badRoot=root.appendingPathComponent("bad");let badURL=historyURL(badRoot,"bad")
  try FileManager.default.createDirectory(at:badURL.deletingLastPathComponent(),withIntermediateDirectories:true)
  let broken=Data("BROKEN".utf8);try broken.write(to:badURL)
  let badService=RenderCatalogService(root:badRoot)
  let bad=await badService.history(jobID:"bad",incoming:entries("bad",10),cursor:nil,limit:40,coverage:"fixture",scope:"scope")
  check(bad.persistenceError != nil && bad.nextCursor==nil && bad.pageCursor==nil,"corrupt history claimed durable navigation")
  check(try Data(contentsOf:badURL)==broken,"corrupt durable file overwritten")
  check(await badService.historyCacheStats().scopes==0,"unreadable scope admitted")
  // Failed refreshed write preserves prior cache and prior durable file.
  let failureRoot=root.appendingPathComponent("failure");let failure=RenderCatalogService(root:failureRoot)
  let original=await failure.history(jobID:"failure",incoming:entries("old",100),cursor:nil,limit:40,coverage:"fixture",scope:"scope")
  let output=failureRoot.appendingPathComponent("Outputs");let moved=failureRoot.appendingPathComponent("SavedOutputs")
  let saved=try Data(contentsOf:historyURL(failureRoot,"failure"))
  try FileManager.default.moveItem(at:output,to:moved);try Data("BLOCKED".utf8).write(to:output)
  let failed=await failure.history(jobID:"failure",incoming:entries("new",200),cursor:nil,limit:40,coverage:"fixture",scope:"scope")
  check(failed.persistenceError != nil && failed.nextCursor==nil,"failed write presented as saved")
  check(await failure.historyCacheStats().entries==100,"failed write replaced durable cache")
  let oldPage=await failure.history(jobID:"failure",incoming:[],cursor:original.nextCursor,limit:40,coverage:"fixture",scope:"scope")
  check(oldPage.totalKnown==100,"failed write lost earlier navigable cache")
  check(try Data(contentsOf:moved.appendingPathComponent(historyURL(failureRoot,"failure").lastPathComponent))==saved,"write error lost earlier durable JSON")
  // Validate cancellation/generation after preparing input, before write/admission.
  let cancelledRoot=root.appendingPathComponent("cancel");let cancelled=RenderCatalogService(root:cancelledRoot);let freshness=Freshness()
  let cancelledPage=await cancelled.history(jobID:"cancel",incoming:entries("cancel",100),cursor:nil,limit:40,coverage:"fixture",scope:"scope",isCurrent:{await freshness.valid()})
  check(cancelledPage.entries.isEmpty && cancelledPage.totalKnown==nil,"stale request returned prepared rows")
  check(await cancelled.historyCacheStats().scopes==0 && !FileManager.default.fileExists(atPath:historyURL(cancelledRoot,"cancel").path),"stale request wrote or admitted")
  let task=Task {await cancelled.history(jobID:"task",incoming:entries("task",100),cursor:nil,limit:40,coverage:"fixture",scope:"scope")};task.cancel();_=await task.value
  check(await cancelled.historyCacheStats().scopes==0,"cancelled task admitted")
  // Controller behavior: traverse a durable dataset, bounded replacement, backwards and close.
  let uiService=RenderCatalogService(root:root.appendingPathComponent("controller"));let uiRows=entries("controller",237)
  let job=RenderDashboard.mac(MacJob(id:"controller",titre:"Controller",sous:nil,total:1,faites:1,en_cours:[],latest:[],times:[],proc:nil),health:SourceHealth(),projectID:"fixture",workType:nil,previews:[])
  let controller=HistoryController()
  let loader:HistoryController.Loader={_,cursor,limit in await uiService.history(jobID:"controller",incoming:cursor==nil ? uiRows : [],cursor:cursor,limit:limit,coverage:"fixture",scope:"scope")}
  controller.load(job:job,direction:.refresh,loader:loader);try await wait(controller)
  var uiSeen=controller.items.map(\.id)
  while controller.cursor != nil {controller.load(job:job,direction:.next,loader:loader);try await wait(controller);check(controller.items.count<=40,"controller retained growing history");uiSeen+=controller.items.map(\.id)}
  check(uiSeen==uiRows.reversed().map(\.id),"UI window traversal has missing rows")
  while controller.previousCursor != nil {controller.load(job:job,direction:.previous,loader:loader);try await wait(controller)}
  check(controller.items.first?.id=="controller-236","controller previous cannot reach first")
  controller.cancel();check(controller.items.isEmpty && controller.cursor==nil && controller.previousCursor==nil && controller.known==nil,"close retains history window")
  controller.load(job:job,direction:.refresh,loader:{_,_,_ in try? await Task.sleep(for:.milliseconds(20));return RenderHistoryPage(entries:uiRows,nextCursor:"bad",totalKnown:237,coverage:"late",snapshotRevision:1)})
  controller.cancel();try await Task.sleep(for:.milliseconds(30));check(controller.items.isEmpty && !controller.loading,"cancelled late response repopulates controller")
  print("F5HistoryTests: \(checks) assertions passed; isolated metadata/JSON and controller, no UI/runtime/network")
 }
}
