import Foundation
import CryptoKit
@main enum ArchiveDataProtectionTests {
 static var checks=0
 static func check(_ value:Bool,_ message:String){checks+=1;precondition(value,message)}
 static func job(_ id:String,active:Bool)->RenderDashboardJob {
  var h=SourceHealth();h.online=true;h.observedAt=Date()
  return RenderDashboard.mac(MacJob(id:id,titre:"SIMULATED",sous:nil,total:10,faites:active ? 3 : 10,en_cours:[],latest:[],times:[],proc:active ? MacProcess(cpu:"1",ram_mo:1,duree:"00:01") : nil),health:h,projectID:"fixture",workType:nil)
 }
 @MainActor static func main() async throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent("autoren-archive-protection-"+UUID().uuidString)
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
  defer {try? FileManager.default.removeItem(at:root)}
  let sentinels=["Renders/frame.png","Sources/scene.blend","Catalog/Outputs/retained-history.json"]
  var originals:[String:Data]=[:]
  for name in sentinels {
   let url=root.appendingPathComponent(name);try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
   let bytes=Data("SIMULATED sentinel \(name)".utf8);try bytes.write(to:url);originals[name]=bytes
  }
  let done=job("done",active:false);let active=job("active",active:true);let jobs=[done,active]
  let snapshot=RenderCatalogSnapshot(revision:1,generatedAt:Date(),jobs:jobs,projects:RenderDashboard.projects(jobs),works:[],knownJobCount:2,observedJobCount:2,stateCounts:RenderCatalogStateCounts(),persistenceIssue:nil)
  let model=MonitorModel.fixture(snapshot:snapshot,storageRoot:root)
  let configURL=root.appendingPathComponent("config.json");let initial=try Data(contentsOf:configURL)
  check(!model.setJobArchived(true,forJobID:active.id),"running job can be removed from follow through archive")
  check(try Data(contentsOf:configURL)==initial,"refused active archive mutates preferences")
  check(model.archiveCompletedJobs()==1,"bulk archive includes active or misses completed")
  for _ in 0..<100 {if model.catalogSnapshot.archivedJobCount==1 {break};try await Task.sleep(for:.milliseconds(10))}
  let archivedConfig=try JSONDecoder().decode(AppConfig.self,from:Data(contentsOf:configURL))
  check(Set(archivedConfig.jobArchives.keys)==[done.id],"archive preference IDs incorrect")
  check(Set(model.catalogSnapshot.jobs.map(\.id))==Set(jobs.map(\.id)),"archive deletes catalogue jobs")
  for name in sentinels {check(try Data(contentsOf:root.appendingPathComponent(name))==originals[name],"archive modifies or deletes source/render/history")}
  model.stop();await model.waitForShutdown()
  let reopened=MonitorModel.fixture(snapshot:snapshot,storageRoot:root)
  _=reopened.setJobContext(nil,forJobID:done.id)
  for _ in 0..<100 {if reopened.catalogSnapshot.archivedJobCount==1 {break};try await Task.sleep(for:.milliseconds(10))}
  check(reopened.catalogSnapshot.jobs.first(where:{$0.id==done.id})?.isArchived==true,"fresh instance loses archive preference")
  check(reopened.setJobArchived(false,forJobID:done.id),"restore rejected")
  for _ in 0..<100 {if reopened.catalogSnapshot.archivedJobCount==0 {break};try await Task.sleep(for:.milliseconds(10))}
  check(reopened.catalogSnapshot.knownJobCount==2 && reopened.catalogSnapshot.archivedJobCount==0,"restore does not recover follow list")
  check(reopened.catalogSnapshot.jobs.first(where:{$0.id==active.id})?.activity == .running,"archive/restore changes active job activity")
  let persisted=try JSONDecoder().decode(AppConfig.self,from:Data(contentsOf:configURL));check(persisted.jobArchives.isEmpty,"restore is not persisted")
  let catalogue=root.appendingPathComponent("Catalog/jobs.json")
  let records=(try JSONSerialization.jsonObject(with:Data(contentsOf:catalogue)) as? [String:Any])?["records"] as? [String:Any]
  check(Set(records?.keys.map {$0} ?? [])==Set(jobs.map(\.id)),"durable catalogue loses IDs on archive/restore")
  for name in sentinels {check(try Data(contentsOf:root.appendingPathComponent(name))==originals[name],"restore modifies or deletes source/render/history")}
  let backups=try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).filter {$0.lastPathComponent.hasPrefix("config.before-preference-change-")}
  check(!backups.isEmpty,"archive/restore not recoverable via private preferences backup")
  reopened.stop();await reopened.waitForShutdown()
  print("ArchiveDataProtectionTests: \(checks) assertions PASS; isolated fixtures only, no live config/render/source/catalogue deletion")
 }
}
