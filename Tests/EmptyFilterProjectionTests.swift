import Foundation
struct TestFailure:Error {let message:String}
@main enum EmptyFilterProjectionTests {
 static var checks=0
 static func check(_ value:Bool,_ message:String) throws {checks+=1;if !value {throw TestFailure(message:message)}}
 static func job(_ id:String,archived:Bool)->RenderDashboardJob {
  var h=SourceHealth();h.online=true;h.observedAt=Date()
  var j=RenderDashboard.mac(MacJob(id:id,titre:"SIMULATED",sous:nil,total:10,faites:10,en_cours:[],latest:[],times:[],proc:nil),health:h,projectID:"fixture",workType:.video)
  j.workID="work-"+id;j.workTitle="SIMULATED";if archived {j.archivedAt=Date(timeIntervalSince1970:1700000000)};return j
 }
 @MainActor static func main() throws {
  let suite=CommandLine.arguments[1];precondition(suite.hasPrefix("fr.robtech.autorender.empty-filter-test."));let defaults=UserDefaults(suiteName:suite)!
  defer {defaults.removePersistentDomain(forName:suite);defaults.synchronize()}
  let archives=[job("A",archived:true),job("B",archived:true),job("C",archived:true)]
  var other=job("outside",archived:false);other.projectID="elsewhere"
  let jobs=archives+[other];let works=jobs.map {RenderCatalogWork(id:$0.workID!,projectID:$0.projectID,title:"SIMULATED",workType:.video,jobs:[$0])}
  let snapshot=RenderCatalogSnapshot(revision:1,generatedAt:Date(),jobs:jobs,projects:RenderDashboard.projects(jobs),works:works,knownJobCount:4,observedJobCount:4,stateCounts:RenderCatalogStateCounts(),persistenceIssue:nil)
  let dates=Dictionary(uniqueKeysWithValues:archives.map {($0.id,$0.archivedAt!)})
  let prefs=try JSONEncoder().encode(AppConfig(jobArchives:dates));defaults.set(prefs,forKey:"QA.ExpectedArchivePreferences")
  let selection=CatalogSelectionController(defaults:defaults);selection.choose(archives[1],workID:archives[1].workID!)
  let selected=[selection.projectID,selection.workID,selection.jobID];let store=CatalogPresentationStore();let scope=CatalogScope.archived
  for (query,source,type) in [("",Filter.shadow,WorkFilter.all),("no-result",Filter.all,WorkFilter.all),("",Filter.all,WorkFilter.audio)] {
   store.rebuild(snapshot,query:query,scope:scope,source:source,type:type);selection.reconcile(store)
   try check(store.visibleProjects.isEmpty,"empty filters retain project header projection")
   try check(store.visibleWorksByProject[selection.projectID]?.isEmpty ?? true,"empty filters retain visible works")
   try check(store.visibleJobIDs.isEmpty,"empty filters retain filtered versions")
   try check([selection.projectID,selection.workID,selection.jobID]==selected,"empty filters rewrite selected IDs")
   try check(defaults.data(forKey:"QA.ExpectedArchivePreferences")==prefs,"empty filters mutate archive preferences")
   // Exact declared reset contract: secondary filters cleared, scope and selected IDs retained.
   store.rebuild(snapshot,query:"",scope:scope,source:.all,type:.all);selection.reconcile(store)
   try check(store.visibleJobIDs==Set(archives.map(\.id)),"clear filters does not recover exact three archives")
   try check(store.visibleWorksByProject[selection.projectID]?.count==3,"clear filters does not recover archived work list")
   try check([selection.projectID,selection.workID,selection.jobID]==selected,"clear filters changes selected archive")
   try check(defaults.data(forKey:"QA.ExpectedArchivePreferences")==prefs,"clear filters changes archive dates/IDs")
   try check(!store.visibleJobIDs.contains(other.id),"clear filters drops Archives scope")
  }
  try check(snapshot.jobs.count==4 && snapshot.jobs.filter(\.isArchived).count==3,"filter/reset deletes catalogue fixtures")
  print("EmptyFilterProjectionTests: \(checks) assertions PASS; projection/reset contract only; native View action and glass NOT tested")
 }
}
