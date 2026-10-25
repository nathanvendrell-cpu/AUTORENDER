import Foundation

@main enum MenuBarPresentationTests {
    static var checks = 0
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1; precondition(condition(), message)
    }
    static func job(_ id: String = "test", age: Double = 0, source: RenderSource = .macMonitor,
                    completed: Int = 3, total: Int = 10, post: RenderProgress? = nil) -> RenderDashboardJob {
        var job = RenderDashboardJob(id: id, title: id, projectID: "fixture", source: source, workType: .video,
            rawCount: completed, postCount: post?.completed, rawProgress: RenderProgress(completed: completed, total: total),
            postProgress: post, totalProvenance: "simulated counters", activity: .running, isFresh: true,
            observedAt: now.addingTimeInterval(-age), lastActivity: nil, historicalMedianSeconds: nil,
            sampledOutputsLastHour: nil, eta: nil, historicalETA: nil, process: nil, gpu: nil, gpuRaw: nil,
            plans: [], tasks: [], stageDescription: nil, previewEntries: [])
        job.taskQualification = .nativeRenderCommand
        job.progressObservedAt = now; job.estimatedRemainingSeconds = 120
        return job
    }
    static func snapshot(_ jobs: [RenderDashboardJob], running: Int? = nil) -> RenderCatalogSnapshot {
        var counts = RenderCatalogStateCounts(); counts.running = running ?? jobs.filter(\.isDetectedActiveRender).count
        return RenderCatalogSnapshot(revision: 1, generatedAt: now, jobs: jobs, projects: [], works: [],
            knownJobCount: jobs.count, observedJobCount: jobs.count, stateCounts: counts, persistenceIssue: nil)
    }
    static func present(_ jobs: [RenderDashboardJob], observation: MenuBarObservation = .confirmed,
                        limit: Int = 40, detail: Int = 12) -> MenuBarPresentation {
        .make(snapshot: snapshot(jobs), observation: observation, now: now, titleLimit: limit, tooltipJobLimit: detail)
    }
    @MainActor static func main() {
        check(present([]).title == "Aucun actif détecté", "Confirmed absence")
        check(present([], observation: .refreshing).title == "Actualisation…", "Refresh is not absence")
        check(present([], observation: .uncertain("réseau")).tooltip.contains("n’est pas confirmée"), "Failure is not absence")
        let one = present([job("SampleScene")])
        check(one.title.contains("SampleScene") && one.title.contains("30%") && one.title.contains("≈2min"), "Name/progress/time automatic")
        check(one.tooltip.contains("3/10"), "Real counters in tooltip")
        check(present([job(age: 30)]).activeIDs.count == 1, "Native boundary")
        check(present([job(age: 30.001)]).title == "Activité incertaine", "Native expiry")
        check(present([job(age: -0.001)]).activeIDs.isEmpty, "Future rejected")
        check(present([job(age: 120, source: .shadowMonitor)]).activeIDs.count == 1, "Shadow boundary")
        check(present([job(age: 120.001, source: .shadowMonitor)]).title == "Activité incertaine", "Shadow expiry")
        check(present([job()], observation: .uncertain("PC perdu")).activeIDs.count == 1, "Fresh individual survives uncertainty")
        var stale = job(); stale.isFresh = false
        var archive = job(); archive.archivedAt = now
        var historical = job(); historical.retainedHistorical = true
        var unqualified = job(); unqualified.taskQualification = nil
        check(present([stale, archive, historical, unqualified]).activeIDs.isEmpty, "No history/archive/unqualified activity")
        var noTime = job(); noTime.progressObservedAt = now.addingTimeInterval(-21)
        check(present([noTime]).title.contains("≈2min"), "Qualified ETA survives long frame cadence")
        noTime.progressObservedAt = now.addingTimeInterval(1)
        check(present([noTime]).title.contains("≈2min"), "Formatter consumes model ETA qualification")
        for seconds in [Double.nan, .infinity, -1] {
            noTime = job(); noTime.estimatedRemainingSeconds = seconds
            check(!present([noTime]).title.contains("min"), "Invalid ETA excluded")
        }
        noTime = job(); noTime.eta = now.addingTimeInterval(12060); noTime.estimatedRemainingSeconds = 999
        check(present([noTime]).title.contains("≈3h21"), "Absolute ETA with hours/minutes")
        noTime.eta = now.addingTimeInterval(-1)
        check(!present([noTime]).title.contains("min"), "Overdue ETA is unknown rather than zero or fallback")
        var temporalOnly = job(total: 0); temporalOnly.eta = now.addingTimeInterval(180)
        check(present([temporalOnly]).title.contains("≈3min") && !present([temporalOnly]).title.contains("%"), "Qualified temporal ETA without counters")
        let standardPC = present([job("PC", source: .shadowMonitor)])
        check(standardPC.title.contains("30%") && !standardPC.title.contains("B30") && !standardPC.title.contains("P?"), "Single stage PC has no artificial post stage")
        let dual = present([job("A", completed: 2), job("B", completed: 9)])
        check(dual.title.contains("20%") && dual.title.contains("+1") && !dual.title.contains("110%"), "No aggregate percentages")
        check(dual.tooltip.contains("90%") && dual.tooltip.contains("20%"), "All individual progress details")
        let pc = present([job("PC", source: .shadowMonitor, completed: 8, post: RenderProgress(completed: 2, total: 10))])
        check(pc.title.contains("B80% P20%") && pc.tooltip.contains("Brut 8/10"), "Stage progress separated")
        check(present([job(completed: Int.max - 1, total: Int.max)]).title.contains("99.9%"), "No floating premature 100")
        let many = (0..<20).map { job("job-\($0)") }
        check(present(many).omittedTooltipJobs == 8 && present(many).tooltip.contains("limite du détail : 12"), "Explicit detail cap")
        check(present(many, detail: 0).omittedTooltipJobs == 20, "Zero detail safe")
        for limit in 1...96 {
            check(present([job(String(repeating: "é😀", count: 100))], limit: limit).title.count <= limit, "Unicode bounded title")
            check(present(many, limit: limit).title.count <= limit, "Multiple bounded title")
        }
        check(present([job("A\nB\u{202E}C")]).title.contains("A B C"), "Control/newline sanitized")
        let invalidData = Data("{\"completed\":3,\"total\":0}".utf8)
        let invalid = try! JSONDecoder().decode(RenderProgress.self, from: invalidData)
        let invalidPC = present([job(source: .shadowMonitor, total: 0, post: invalid)])
        check(!invalidPC.title.contains("%"), "Decoded invalid counters excluded")
        let mismatch = MenuBarPresentation.make(snapshot: snapshot([], running: 1), observation: .confirmed, now: now)
        check(mismatch.title == "Activité incertaine", "Count mismatch cannot claim zero")
        var gui = job("GUI", total: 0); gui.estimatedRemainingSeconds = nil
        gui.currentFrame = 0; gui.renderStartedAt = now.addingTimeInterval(-121)
        let guiTitle = present([gui]).title
        check(guiTitle.contains("image 0") && guiTitle.contains("2min éc.") && !guiTitle.contains("%"), "GUI frame zero and elapsed without invented progress")
        gui.currentFrame = -42
        check(present([gui]).title.contains("image -42"), "Negative frame is a number rather than count")
        gui.renderStartedAt = now.addingTimeInterval(1)
        check(!present([gui]).title.contains("éc."), "Future render start excluded")
        gui.renderStartedAt = Date(timeIntervalSince1970: .nan)
        check(!present([gui]).title.contains("éc."), "Invalid render start excluded")
        gui.renderStartedAt = now; gui.currentFrame = nil
        check(present([gui]).title.contains("0s éc."), "Real zero elapsed is valid")
        gui.eta = now.addingTimeInterval(180)
        check(present([gui]).title.contains("≈3min") && !present([gui]).tooltip.contains("éc."), "ETA takes precedence over elapsed")
        var diagnosticRows: [String] = []
        let diagnostic = StartupDiagnostic(requested: true, canonical: true, startedAt: 100, write: { diagnosticRows.append($0) })
        func record(_ title: String, at uptime: TimeInterval = 101) {
            diagnostic.record(version: "test", build: "1", pid: 1, assignedTitle: title,
                itemWidth: 260, buttonWidth: 250, observation: "uncertain", loginState: "requiresApproval", loginError: false, at: uptime)
        }
        record("title"); record("title")
        check(diagnosticRows.count == 1, "Duplicate state diagnostic suppressed")
        record("/private/title")
        check(diagnosticRows.count == 2 && !diagnosticRows[1].contains("/private/title") && diagnosticRows[1].contains("titleRedacted"), "Diagnostic withholds paths")
        for index in 0..<20 { record("title-\(index)") }
        check(diagnosticRows.count == 10 && !diagnostic.isRecording(at: 102), "Diagnostic capped at ten states")
        let expired = StartupDiagnostic(requested: true, canonical: true, startedAt: 100)
        check(!expired.isRecording(at: 190), "Diagnostic expires at ninety seconds without timer")
        check(!StartupDiagnostic(requested: true, canonical: false, startedAt: 100).isRecording(at: 101), "Diagnostic canonical gate")
        check(!StartupDiagnostic(requested: false, canonical: true, startedAt: 100).isRecording(at: 101), "Diagnostic explicit opt-in")
        let width: (String) -> CGFloat = { text in text.reduce(0) { $0 + ($1 == "W" ? 20 : 5) } }
        let wideTitle = String(repeating: "W", count: 40)
        let fitted = MenuBarWidthPolicy.fit(wideTitle, reservedWidth: 40, measure: width)
        check(width(fitted) + 40 <= 260 && fitted.contains("…"), "Point bound handles wide glyphs")
        check(MenuBarWidthPolicy.fit("abc", reservedWidth: 40, measure: width) == "abc", "Short width unchanged")
        check(MenuBarWidthPolicy.fit("abc", maximumWidth: 20, reservedWidth: 40, measure: width).isEmpty, "No text budget")
        check(MenuBarWidthPolicy.fit("😀WW😀", maximumWidth: 50, reservedWidth: 10, measure: width).contains("…"), "Unicode point clipping")
        check(MenuBarWidthPolicy.fit("abc", reservedWidth: 40, measure: { _ in .infinity }).isEmpty, "Invalid measurement safe")
        let inert = InertLoginItemService()
        check(inert.state == .unavailable, "Inert service has no real status")
        do { try inert.register(); check(false, "Inert register must fail") } catch { check(true, "Inert register blocked") }
        do { try inert.unregister(); check(false, "Inert unregister must fail") } catch { check(true, "Inert unregister blocked") }
        #if AUTORENDER_UI_HARNESS
        check(LoginItemServiceFactory.make() is InertLoginItemService, "Harness factory inert")
        #endif
        let fake = FakeLoginService()
        let controller = LoginItemController(service: fake, mayRegister: true)
        check(fake.registerCalls == 0 && fake.unregisterCalls == 0, "Initialization is read only")
        fake.afterRegister = .requiresApproval; controller.enable()
        check(controller.state == .requiresApproval && !controller.label.contains("activée"), "Approval not enabled")
        fake.afterRegister = .enabled; controller.enable()
        check(controller.state == .enabled, "Post-register state read")
        fake.fail = true; controller.disable()
        check(controller.error != nil && controller.state == .enabled, "Failure preserves actual state")
        fake.fail = false; controller.disable()
        check(controller.state == .disabled && controller.error == nil, "Disable reads service")
        let blocked = LoginItemController(service: fake, mayRegister: false)
        let previous = fake.registerCalls; blocked.enable(); blocked.disable()
        check(fake.registerCalls == previous && blocked.error != nil, "Noncanonical cannot register")
        let home = URL(fileURLWithPath: "/simulated-home")
        let canonical = home.appendingPathComponent("Applications/AUTORENDER.app")
        check(LoginItemController.isCanonical(bundleURL: canonical, homeURL: home, bundleIdentifier: "fr.robtech.rendubar"), "Canonical gate")
        check(!LoginItemController.isCanonical(bundleURL: canonical, homeURL: home, bundleIdentifier: "wrong"), "Wrong ID gate")
        check(!LoginItemController.isCanonical(bundleURL: URL(fileURLWithPath: "/tmp/Products.noindex/AUTORENDER.app"), homeURL: home, bundleIdentifier: "fr.robtech.rendubar"), "Products gate")
        print("PASS \(checks) menu-bar and mocked login-item checks; no system registration")
    }
}
@MainActor final class FakeLoginService: LoginItemService {
    var state: LoginItemState = .disabled
    var afterRegister: LoginItemState = .enabled
    var registerCalls = 0, unregisterCalls = 0
    var fail = false
    func register() throws { registerCalls += 1; if fail { throw CocoaError(.fileReadUnknown) }; state = afterRegister }
    func unregister() throws { unregisterCalls += 1; if fail { throw CocoaError(.fileReadUnknown) }; state = .disabled }
    func openSettings() {}
}
