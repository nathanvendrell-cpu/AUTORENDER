import Foundation
@main enum ArchiveDashboardRouteTests {
 static var checks=0
 static func check(_ value:Bool,_ message:String){checks+=1;precondition(value,message)}
 static func job(_ id:String,_ project:String,archived:Bool,active:Bool=false)->RenderDashboardJob {
  var health=SourceHealth();health.online=true;health.observedAt=Date()
  var j=RenderDashboard.mac(MacJob(id:id,titre:"Same visible title",sous:nil,total:10,faites:active ? 3 : 10,en_cours:[],latest:[],times:[],proc:active ? MacProcess(cpu:"1",ram_mo:1,duree:"00:01") : nil),health:health,projectID:project,workType:.video)
  j.workID="same-work";j.workTitle="Same work title";j.projectTitle="Same project title"
  j.taskQualification=active ? .nativeRenderCommand:nil // SIMULATED qualified task, not legacy API attribution.
  if archived {j.archivedAt=Date(timeIntervalSince1970:1700000000)}
  return j
 }
 @MainActor static func main() async throws {
  let suites=Array(CommandLine.arguments.dropFirst())
  precondition(suites.count==2 && suites.allSatisfy {$0.hasPrefix("fr.robtech.autorender.archive-route-test.")})
  let defaults=suites.map {UserDefaults(suiteName:$0)!}
  defer {for (i,suite) in suites.enumerated(){defaults[i].removePersistentDomain(forName:suite)}}
  let archived=job("archived-A","A",archived:true);let other=job("archived-B","B",archived:true);let active=job("active-A","A",archived:false,active:true)
  let jobs=[archived,other,active]
  let works=[RenderCatalogWork(id:"same-work",projectID:"A",title:"Same work title",workType:.video,jobs:[archived,active]),RenderCatalogWork(id:"same-work",projectID:"B",title:"Same work title",workType:.video,jobs:[other])]
  let snapshot=RenderCatalogSnapshot(revision:1,generatedAt:Date(),jobs:jobs,projects:RenderDashboard.projects(jobs),works:works,knownJobCount:3,observedJobCount:3,stateCounts:RenderCatalogStateCounts(),persistenceIssue:nil)
  let store=CatalogPresentationStore();let mini=CatalogSelectionController(defaults:defaults[0]);let dashboard=CatalogSelectionController(defaults:defaults[0]);let independent=CatalogSelectionController(defaults:defaults[1])
  store.rebuild(snapshot,query:"contradiction",scope:.follow,source:.shadow,type:.audio)
  check(store.visibleJobIDs.isEmpty,"fixture filters did not hide archived target")
  mini.openInDashboard(archived,workID:"same-work")
  guard let request=mini.dashboardNavigation else {preconditionFailure("navigation request absent")}
  check(request.scope == .archived,"archived job routes to follow")
  check(request.projectID==archived.projectID && request.workID=="same-work" && request.jobID==archived.id,"route uses titles or wrong identities")
  try await Task.sleep(for:.milliseconds(10))
  check(dashboard.dashboardNavigation?.id==request.id,"same namespace dashboard did not receive event")
  check(independent.dashboardNavigation==nil,"other namespace received event")
  dashboard.apply(request)
  // Exercise the projection contract used by ContentView after clearing contradictory filters.
  store.rebuild(snapshot,query:"",scope:request.scope,source:.all,type:.all);dashboard.reconcile(store)
  check(store.visibleJobIDs.contains(archived.id),"archive not accessible after projection contract")
  check(dashboard.projectID=="A" && dashboard.workID=="same-work" && dashboard.jobID==archived.id,"reconcile picks same title from another project")
  check(store.work(projectID:dashboard.projectID,workID:dashboard.workID)?.jobs.first(where:{$0.id==dashboard.jobID})?.id==archived.id,"exact version unavailable after route")
  mini.openInDashboard(archived,workID:"same-work")
  check(mini.dashboardNavigation?.id != request.id,"same-job repeat event not unique")
  check(mini.dashboardNavigation?.jobID==request.jobID,"repeat loses identity")
  mini.openInDashboard(active,workID:"same-work")
  guard let live=mini.dashboardNavigation else {preconditionFailure("active request absent")}
  check(live.scope == .direct,"qualified active route must request En cours")
  dashboard.apply(live);store.rebuild(snapshot,query:"",scope:live.scope);dashboard.reconcile(store)
  check(dashboard.jobID==active.id && store.visibleJobIDs.contains(active.id),"qualified active version not selected in En cours")
  check(!active.canArchive && !active.isArchived && archived.isArchived,"navigation changed archive status or active protection")
  defaults[0].synchronize()
  let freshDefaults=UserDefaults(suiteName:suites[0])!;let reopened=CatalogSelectionController(defaults:freshDefaults)
  check(reopened.dashboardNavigation==nil,"navigation event replays after relaunch")
  check(reopened.projectID=="A" && reopened.workID=="same-work" && reopened.jobID==active.id,"selection identity did not persist")
  independent.openInDashboard(other,workID:"same-work")
  let firstAgain=CatalogSelectionController(defaults:freshDefaults)
  check(firstAgain.jobID==active.id && firstAgain.dashboardNavigation==nil,"isolated namespace leaked another selection")
  check(independent.projectID=="B" && independent.jobID==other.id,"second namespace route wrong")
  let future=DashboardNavigationRequest(id:"future-request",projectID:"A",workID:"same-work",jobID:"future-job-not-in-snapshot",scopeValue:"FUTURE_SCOPE")
  check(future.scope == .all,"unknown scope fallback changed")
  dashboard.apply(future);store.rebuild(snapshot,query:"",scope:future.scope);dashboard.reconcile(store)
  check(dashboard.jobID==future.jobID,"unknown version silently replaced by another job")
  check(store.work(projectID:dashboard.projectID,workID:dashboard.workID)?.jobs.contains(where:{$0.id==dashboard.jobID})==false,"unknown version aliases known job")
  check(defaults[0].object(forKey:"jobArchives")==nil && defaults[1].object(forKey:"jobArchives")==nil,"UI navigation writes archive data")
  defaults[1].set("{broken",forKey:"AUTORENDER.DashboardNavigation")
  let bad=CatalogSelectionController(defaults:defaults[1]);check(bad.dashboardNavigation==nil,"legacy persisted route replays")
  check(bad.jobID==other.id,"malformed route rewrites persisted job selection")
  try await Task.sleep(for:.milliseconds(10))
  mini.openInDashboard(archived,workID:"same-work");try await Task.sleep(for:.milliseconds(10))
  let pending=dashboard.dashboardNavigation!.id
  dashboard.consumeDashboardNavigation("wrong-event")
  check(dashboard.dashboardNavigation?.id==pending,"wrong consume clears new event")
  dashboard.consumeDashboardNavigation(pending)
  check(dashboard.dashboardNavigation==nil,"event not consumed")
  let masks:Set<String>=[archived.id,active.id]
  check(!CompactVisibility.isVisible(archived,scope:.follow,hiddenIDs:masks),"hidden old render remains in follow")
  check(CompactVisibility.isVisible(archived,scope:.all,hiddenIDs:masks) && !CompactVisibility.isVisible(archived,scope:.archived,hiddenIDs:masks),"masked terminal must stay hidden from Archives until restored")
  check(CompactVisibility.isVisible(archived,scope:.archived,hiddenIDs:[]),"global restore must recover the archive")
  check(CompactVisibility.isProtected(active) && CompactVisibility.isVisible(active,scope:.follow,hiddenIDs:masks),"fresh active masked from follow")
  var historical=active;historical.isFresh=false;historical.retainedHistorical=true
  check(!CompactVisibility.isProtected(historical),"historical job treated as live protected")
  check(jobs.filter(\.isArchived).count==2 && archived.archivedAt==Date(timeIntervalSince1970:1700000000),"route/mask modifies archive ID/date state")
  print("ArchiveDashboardRouteTests: \(checks) assertions PASS; two isolated defaults namespaces; projection contract tested, native filter-reset/geometry NOT tested")
 }
}
