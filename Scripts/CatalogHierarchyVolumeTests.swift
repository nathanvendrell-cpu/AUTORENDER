import Foundation
import Darwin

@main enum CatalogHierarchyVolumeTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1; precondition(value(), message)
    }
    static func context(_ job: CatalogHierarchyRecord) -> CatalogHierarchyContext {
        let number = Int(job.id)!
        return CatalogHierarchyContext(subprojectID: "sub-\((number / 200) % 5)", subprojectTitle: "Sous-projet \((number / 200) % 5)",
            sceneID: "scene-\((number / 1000) % 10)", sceneTitle: "Scène \((number / 1000) % 10)")
    }
    static func main() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let done = CatalogHierarchyRecord(id: "fixture", title: "Version simulée", projectID: "fixture", projectTitle: nil,
            versionLabel: nil, isDetectedActiveRender: false, isFinishedRender: true, observedAt: date, lastActivity: nil)
        let active = CatalogHierarchyRecord(id: "active-fixture", title: "Version simulée", projectID: "fixture", projectTitle: nil,
            versionLabel: nil, isDetectedActiveRender: true, isFinishedRender: false, observedAt: date, lastActivity: nil)
        let fixtureStart = ProcessInfo.processInfo.systemUptime
        var jobs = (0..<50_000).map { number -> CatalogHierarchyRecord in
            var job = number < 8 ? active : done
            job.id = String(number); job.projectID = "project-\(number % 200)"
            job.projectTitle = "Projet \(number % 200)"; job.versionLabel = "Version \(number)"
            return job
        }
        let fixtureSeconds = ProcessInfo.processInfo.systemUptime - fixtureStart
        let index = CatalogHierarchyIndex()
        let buildStart = ProcessInfo.processInfo.systemUptime
        index.rebuild(jobs, context: context)
        let indexSeconds = ProcessInfo.processInfo.systemUptime - buildStart
        check(index.indexedJobs == 50_000 && index.jobsByID.count == 50_000, "No historical identities lost")
        check(Set(index.jobsByID.keys).count == 50_000, "Stable IDs distinct")
        check(index.rows(projectID: "project-0").count == 5, "History starts collapsed at subproject level")
        check(index.rows(projectID: "project-1").allSatisfy { $0.kind != .version }, "No automatic fifty-thousand cards")
        check(index.reveal(jobID: "49999"), "Reveal exact late version")
        let late = index.rows(projectID: "project-199")
        check(late.contains { $0.jobID == "49999" }, "Late version appears without clicking through thousands")
        check(!late.contains { $0.jobID == "49998" }, "Identical scene names do not cross clients")
        let stableRow = late.first { $0.jobID == "49999" }!.id
        jobs[49_999].versionLabel = "Nom affiché corrigé"
        index.rebuild(jobs, context: context); index.reveal(jobID: "49999")
        check(index.rows(projectID: "project-199").first { $0.jobID == "49999" }?.id == stableRow, "Display rename must not change identity")
        let bounded = CatalogHierarchyIndex(pageSize: 3, maximumRows: 20)
        bounded.rebuild(jobs, context: context)
        var first = bounded.rows(projectID: "project-0")
        check(first.filter { $0.kind == .subproject }.count == 3, "Group page bounded")
        let page = first.first { $0.kind == .page }!
        check(page.pageStart == 1 && page.pageEnd == 3 && page.count == 5, "Honest page counts")
        bounded.turnPage(page.parentID, forward: true)
        let second = bounded.rows(projectID: "project-0")
        check(second.filter { $0.kind == .subproject }.count == 2, "Next page replaces rows rather than accumulating cards")
        check(Set(first.filter { $0.kind == .subproject }.map(\.id)).isDisjoint(with: second.filter { $0.kind == .subproject }.map(\.id)), "No overlapping group pages")
        bounded.turnPage(page.parentID, forward: false)
        check(bounded.rows(projectID: "project-0").map(\.id) == first.map(\.id), "Previous page stable")
        for row in first where row.kind == .subproject { bounded.toggle(row.id) }
        first = bounded.rows(projectID: "project-0")
        for row in first where row.kind == .scene { bounded.toggle(row.id) }
        let dense = bounded.rows(projectID: "project-0")
        check(dense.count <= 20, "Hard projection bound even after expansion")
        check(bounded.rows(projectID: "missing").isEmpty && !bounded.lastProjectionWasLimited, "Unknown project does not reuse another client")
        check(!bounded.reveal(jobID: "missing"), "Missing version never aliases another")
        let activeJobs = jobs.filter(\.isDetectedActiveRender)
        check(activeJobs.count == 8, "All connected fixture sources included without project filter")
        index.rebuild(activeJobs, context: context)
        check(index.indexedJobs == 8 && index.jobsByID.values.allSatisfy(\.isDetectedActiveRender), "Compact index active only")
        var completed = done; completed.id = "0"; completed.projectID = jobs[0].projectID
        jobs[0] = completed
        check(!jobs[0].isDetectedActiveRender && jobs[0].isFinishedRender, "Transition to done does not require archive mutation")
        check(jobs.filter(\.isDetectedActiveRender).count == 7, "Completed job leaves active projection")
        check(jobs.filter(\.isFinishedRender).count == 49_993, "Finished history retains completed identity automatically")
        let unassigned = CatalogHierarchyIndex()
        unassigned.rebuild([jobs[0]], context: { _ in CatalogHierarchyContext(subprojectTitle: "Untrusted label", sceneTitle: "Untrusted scene") })
        check(unassigned.rows(projectID: jobs[0].projectID).first?.title == "Sous-projet non renseigné", "Labels alone never invent hierarchy identities")
        let crowdedJobs = jobs.map { original -> CatalogHierarchyRecord in
            var record = original; record.projectID = "one-project"; record.projectTitle = "Projet unique simulé"; return record
        }
        let crowded = CatalogHierarchyIndex()
        let crowdedStart = ProcessInfo.processInfo.systemUptime
        crowded.rebuild(crowdedJobs, context: { _ in CatalogHierarchyContext(subprojectID: "one-sub", subprojectTitle: "Sous-projet unique", sceneID: "one-scene", sceneTitle: "Scène unique") })
        let crowdedSeconds = ProcessInfo.processInfo.systemUptime - crowdedStart
        check(crowded.indexedJobs == 50_000, "Single-scene history keeps all identities")
        check(crowded.reveal(jobID: "49998"), "Reveal exact late single-scene version")
        let crowdedPage = crowded.rows(projectID: "one-project")
        check(crowdedPage.count <= 200 && crowdedPage.filter { $0.kind == .version }.count == 50, "Fifty-thousand versions still produce only fifty version rows")
        check(crowdedPage.contains { $0.jobID == "49998" }, "Exact late selection on the right page")
        let crowdedPager = crowdedPage.first { $0.kind == .page }!
        check(crowdedPager.count == 50_000 && crowdedPager.pageStart > 50, "Single-scene pagination count and exact jump are honest")
        crowded.turnPage(crowdedPager.parentID, forward: true)
        let nextCrowdedPage = crowded.rows(projectID: "one-project")
        check(nextCrowdedPage.count <= 200 && Set(crowdedPage.compactMap(\.jobID)).isDisjoint(with: nextCrowdedPage.compactMap(\.jobID)), "Single-scene next page replaces rather than accumulates cards")
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let output: [String: Any] = ["fixtureJobs": 50_000, "fixtureSeconds": fixtureSeconds, "peakResidentBytes": usage.ru_maxrss,
            "initialIndexSeconds": indexSeconds, "singleSceneIndexSeconds": crowdedSeconds, "singleSceneRowsMeasured": crowdedPage.count, "maximumMaterializedRows": 20, "denseRowsMeasured": dense.count,
            "assertions": checks, "scope": "Synthetic metadata projection; no native UI, media or application runtime"]
        let data = try! JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        print(String(data: data, encoding: .utf8)!)
        print("PASS \(checks) hierarchy volume checks")
    }
}
