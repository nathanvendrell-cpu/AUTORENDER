import Foundation
@main enum ArchiveDashboardRouteTests {
 static var checks=0
 static func check(_ value:Bool,_ message:String){checks+=1;precondition(value,message)}
 static func job(_ id:String,_ project:String,archived:Bool,active:Bool=false)->RenderDashboardJob {
  var health=SourceHealth();health.online=true;health.observedAt=Date()
  var j=RenderDashboard.mac(MacJob(id:id,titre:"Same visible title",sous:nil,total:10,faites:active ? 3 : 10,en_cours:[],latest:[],times:[],proc:active ? MacProcess(cpu:"1",ram_mo:1,duree:"00:01") : nil),health:health,projectID:project,workType:.video)
  j.workID="same-work";j.workTitle="Same work title";j.projectTitle="Same project title"
  if archived {j.archivedAt=Date(timeIntervalSince1970:1700000000)}
  j.taskQualification = active ? .nativeRenderCommand : nil
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
  check(live.scope == .direct,"qualified active route does not request direct scope")
  dashboard.apply(live);store.rebuild(snapshot,query:"",scope:live.scope);dashboard.reconcile(store)
  check(dashboard.jobID==active.id && store.visibleJobIDs.contains(active.id),"active version not selected in direct")
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
  check(CompactVisibility.isVisible(archived,scope:.all,hiddenIDs:masks) && !CompactVisibility.isVisible(archived,scope:.archived,hiddenIDs:masks),"hidden archive must remain visible only in All")
  guard let restoredMasks=CompactVisibility.toggledHiddenIDs(for:archived,hiddenIDs:masks) else {preconditionFailure("archive visibility cannot be restored")}
  check(!restoredMasks.contains(archived.id) && restoredMasks.contains(active.id) && CompactVisibility.isVisible(archived,scope:.archived,hiddenIDs:restoredMasks),"restoring archive visibility loses IDs or leaves archive hidden")
  check(CompactVisibility.isProtected(active) && CompactVisibility.isVisible(active,scope:.follow,hiddenIDs:masks),"fresh active masked from follow")
  var historical=active;historical.isFresh=false;historical.retainedHistorical=true
  check(!CompactVisibility.isProtected(historical),"historical job treated as live protected")
  check(jobs.filter(\.isArchived).count==2 && archived.archivedAt==Date(timeIntervalSince1970:1700000000),"route/mask modifies archive ID/date state")
  var nativeHealth=SourceHealth();nativeHealth.online=true;nativeHealth.observedAt=Date()
  var native=RenderDashboard.mac(MacJob(id:"native-F12",titre:"F12 complete",sous:nil,total:0,faites:0,en_cours:[],latest:[],times:[],proc:nil),health:nativeHealth,projectID:"native-project",workType:.image)
  native.workID="native-work";native.nativeRenderOutcome="complete";native.archivedAt=Date()
  // The real native-complete adapter uses the terminal activity without inventing counters.
  var nativeObject=try JSONSerialization.jsonObject(with:JSONEncoder().encode(native)) as! [String:Any]
  nativeObject["activity"]=RenderActivity.countsReached.rawValue
  native=try JSONDecoder().decode(RenderDashboardJob.self,from:JSONSerialization.data(withJSONObject:nativeObject))
  check(native.rawProgress==nil && !native.isTerminalCounted && native.isTerminalRender,"native completion fixture must not fabricate counters")
  check(CatalogScope.archived.matches(native) && CatalogScope.dashboardScope(for:native) == .archived,"native complete archive must remain routable")
  mini.openInDashboard(native,workID:"native-work")
  guard let nativeRoute=mini.dashboardNavigation else {preconditionFailure("native archive route absent")}
  check(nativeRoute.jobID==native.id && nativeRoute.projectID==native.projectID && nativeRoute.scope == .archived,"native archive navigation loses identity")
  let nativeSnapshot=RenderCatalogSnapshot(revision:2,generatedAt:Date(),jobs:[native],projects:RenderDashboard.projects([native]),works:[RenderCatalogWork(id:"native-work",projectID:native.projectID,title:"native",workType:.image,jobs:[native])],knownJobCount:1,observedJobCount:1,stateCounts:RenderCatalogStateCounts(),persistenceIssue:nil)
  dashboard.apply(nativeRoute);store.rebuild(nativeSnapshot,query:"",scope:nativeRoute.scope);dashboard.reconcile(store)
  check(store.visibleJobIDs.contains(native.id) && dashboard.jobID==native.id,"native archive disappears after navigation/projection")
  for outcome in ["unknown","cancel"] {
   var nonterminal=native;nonterminal.nativeRenderOutcome=outcome
   check(!nonterminal.isTerminalRender && !CatalogScope.archived.matches(nonterminal) && CatalogScope.dashboardScope(for:nonterminal)==nil,"unknown/cancel must not become terminal archives")
  }
  var oldFinished=archived;oldFinished.archivedAt=nil;oldFinished.isFresh=false;oldFinished.retainedHistorical=true
  check(oldFinished.canArchive && oldFinished.isTerminalRender,"historical complete proof permits reversible archive without live PC")
  oldFinished.archivedAt=Date()
  check(!oldFinished.canArchive && CatalogScope.archived.matches(oldFinished),"historical archived state remains distinct")
  oldFinished.archivedAt=nil
  mini.openInDashboard(oldFinished,workID:"same-work")
  guard let restoredRoute=mini.dashboardNavigation else {preconditionFailure("restored historical route absent")}
  check(restoredRoute.scope == .finished && restoredRoute.jobID==oldFinished.id,"restored historical terminal must route to exact done identity")
  var oldNative=native;oldNative.archivedAt=nil;oldNative.isFresh=false;oldNative.retainedHistorical=true
  check(oldNative.canArchive && !oldNative.isTerminalCounted,"historical native complete archives without manufactured totals")
  oldNative.nativeRenderOutcome=nil
  check(!oldNative.canArchive,"historical unknown cannot be falsely completed")
  check(!active.canArchive,"active remains protected from historical removal flow")
  var contradictory=active;contradictory.nativeRenderOutcome="complete"
  check(!contradictory.canArchive,"running activity plus stale completion token cannot be archived")
  print("ArchiveDashboardRouteTests: \(checks) assertions PASS; two isolated defaults namespaces; projection contract tested, native filter-reset/geometry NOT tested")
 }
}
