import Foundation
import Darwin
@main enum ResourceStoreTests {
 static var checks=0
 static func check(_ ok:Bool,_ message:String) {checks+=1;precondition(ok,message)}
 static func input(_ at:Date)->RenderCatalogInput {
  var h=SourceHealth();h.online=true;h.observedAt=at
  return RenderCatalogInput(revision:1,macJobs:[MacJob(id:"neutral",titre:"Neutral",sous:nil,total:10,faites:10,en_cours:[],latest:[],times:[],proc:nil)],shadow:nil,declaration:nil,config:AppConfig(),knownFolders:[:],entries:[],macEntries:[],folderEntries:[],shadowEntries:[],shadowFolderEntries:[],macHealth:h,shadowHealth:SourceHealth(),folderHealth:SourceHealth(),remoteHealth:SourceHealth())
 }
 @MainActor static func main() async throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent("resource-store-tests-"+UUID().uuidString,isDirectory:true)
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
  defer {try? FileManager.default.removeItem(at:root)}
  let service=RenderCatalogService(root:root.appendingPathComponent("catalog"))
  let first=await service.build(input(Date()))!
  let second=await service.build(input(Date().addingTimeInterval(5)))!
  check(second.revision>first.revision,"UI revision stopped")
  check(await service.catalogueWriteCount==1,"semantic unchanged polling rewrites durable catalogue")
  let entries=(0..<1000).map {RenderEntry(id:"entry-\($0)",source:.macFolder,job:"Neutral",filename:"f.png",modified:Date(timeIntervalSince1970:Double($0)),state:.stable,path:nil,previewURL:nil)}
  let page=await service.history(jobID:"mac:neutral",incoming:entries,cursor:nil,limit:40,coverage:"fixture",scope:"scope")
  let next=await service.history(jobID:"mac:neutral",incoming:[],cursor:page.nextCursor,limit:40,coverage:"fixture",scope:"scope")
  check(next.entries.count==40 && next.snapshotRevision==page.snapshotRevision,"cached pagination changed scope")
  let sorts=await service.historySortCount;let writes=await service.historyWriteCount
  check(sorts==1 && writes==1,"next page repeats full sort/write")
  let configRoot=root.appendingPathComponent("prefs");let store=RenderConfigStore(root:configRoot)
  _=try store.update { $0.folderProjects["/tmp/neutral"]="neutral" }
  let file=configRoot.appendingPathComponent("config.json")
  var raw=try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:Any];raw["foreign_key"]="keep"
  try JSONSerialization.data(withJSONObject:raw).write(to:file)
  _=try store.update { $0.jobContexts["mac:neutral"]=RenderJobContext(projectID:nil,workID:"work",versionID:nil,workTitle:"Named",versionLabel:nil) }
  let updated=try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:Any]
  check(updated["foreign_key"] as? String=="keep","store loses foreign keys")
  let fd=open(configRoot.appendingPathComponent("config.lock").path,O_RDWR)
  defer {close(fd)}
  check(flock(fd,LOCK_EX|LOCK_NB)==0,"fixture lock acquisition failed")
  var denied=false
  do {_=try store.update{$0.macFolders.append("/tmp/new")}} catch {denied=true}
  flock(fd,LOCK_UN)
  check(denied,"concurrent writer not refused")
  let attrs=try FileManager.default.attributesOfItem(atPath:file.path)
  check((attrs[.posixPermissions] as? NSNumber)?.intValue==0o600,"new private config not0600")
  let helper=root.appendingPathComponent("slow-helper.py")
  let pidFile=root.appendingPathComponent("child.pid")
  let python="""
import subprocess,signal,time,sys
child=subprocess.Popen(['/bin/sleep','30'])
open(\(String(reflecting:pidFile.path)),'w').write(str(child.pid))
def stop(*args):
 child.terminate();child.wait(timeout=2);sys.exit(0)
signal.signal(signal.SIGTERM,stop)
time.sleep(30)
"""
  try python.write(to:helper,atomically:true,encoding:.utf8)
  let scanner=ShadowFolderScanner(fixtureHelperURL:helper)
  let task=Task {await scanner.history(["C:/neutral/exports"])}
  for _ in 0..<100 {if FileManager.default.fileExists(atPath:pidFile.path) {break};try await Task.sleep(for:.milliseconds(20))}
  let began=DispatchTime.now().uptimeNanoseconds;scanner.cancel()
  let milliseconds=Double(DispatchTime.now().uptimeNanoseconds-began)/1_000_000
  check(milliseconds<100,"cancel blocks MainActor")
  await scanner.waitForShutdown();_=await task.value
  if let text=try? String(contentsOf:pidFile,encoding:.utf8),let pid=Int32(text) {check(kill(pid,0) != 0 && errno==ESRCH,"owned child survives shutdown")}
  else {preconditionFailure("fixture helper never started")}
  print("ResourceStoreTests: \(checks) assertions passed; no native UI/real renderer/source IO")
 }
}
