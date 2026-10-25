import Foundation
import AppKit
import Sparkle
import CryptoKit

@MainActor
final class NoUIUpdateDriver: NSObject, SPUUserDriver {
    var found: String?
    var finished = false
    var failure: String?
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}
    func showUpdateFound(with item: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        found = item.versionString; reply(.skip); finished = true
    }
    func showUpdateReleaseNotes(with data: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) { failure = "notes" }
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) { failure = "notFound:\((error as NSError).code)"; acknowledgement(); finished = true }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) { failure = "error:\((error as NSError).domain):\((error as NSError).code)"; acknowledgement(); finished = true }
    // Any installer preparation is a failed test, not a permission to show UI.
    func showDownloadInitiated(cancellation: @escaping () -> Void) { failure = "UNEXPECTED_DOWNLOAD"; cancellation(); finished = true }
    func showDownloadDidReceiveExpectedContentLength(_ length: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() { failure = "UNEXPECTED_EXTRACTION"; finished = true }
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) { failure = "UNEXPECTED_INSTALLER"; reply(.skip); finished = true }
    func showInstallingUpdate(withApplicationTerminated terminated: Bool, retryTerminatingApplication: @escaping () -> Void) { failure = "UNEXPECTED_INSTALL"; finished = true }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { failure = "UNEXPECTED_RELAUNCH"; acknowledgement(); finished = true }
    func dismissUpdateInstallation() { finished = true }
    func showUpdateInFocus() {}
}

@main enum SoftwareUpdateHeadlessTests {
    @MainActor static func main() async throws {
        let args = CommandLine.arguments
        if args[1] == "key" {
            let key = Curve25519.Signing.PrivateKey()
            let path = URL(fileURLWithPath: args[2])
            try key.rawRepresentation.base64EncodedData().write(to: path, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            print(key.publicKey.rawRepresentation.base64EncodedString())
            return
        }
        if args[1] == "guards" {
            var checks = 0
            func check(_ value: @autoclosure () -> Bool) { checks += 1; precondition(value()) }
            var safe = true, wantsInstall = true, calls: [SPUUserUpdateChoice] = []
            let base = NoUIUpdateDriver()
            let driver = GuardedSparkleDriver(base: base, safety: { (safe, safe ? "" : "busy") }, confirmReady: { wantsInstall })
            driver.showReady { calls.append($0) }
            check(calls == [.install] && driver.installRequested)
            safe = false; driver.cancelPreparedUpdate()
            check(calls == [.install, .skip] && !driver.installRequested)
            // Wait for Sparkle's dismissal before ordinary quitting, never race an in-flight cancel.
            var cancellationFinished = false
            check(driver.cancelForTermination(completion: { cancellationFinished = true }))
            driver.dismissUpdateInstallation(); check(cancellationFinished)
            check(!driver.cancelForTermination(completion: {}))
            safe = true; wantsInstall = false; calls = []
            driver.showReady { calls.append($0) }
            check(calls == [.skip] && !driver.installRequested)
            driver.dismissUpdateInstallation(); wantsInstall = true; safe = false; calls = []
            driver.showReady { calls.append($0) }
            check(calls == [.skip])
            driver.dismissUpdateInstallation()
            // The confirmation itself may race a render-start notification.
            safe = true; calls = []
            let race = GuardedSparkleDriver(base: base, safety: { (safe, "uncertain") }, confirmReady: { safe = false; return true })
            race.showReady { calls.append($0) }
            check(calls == [.skip] && !race.installRequested)
            // A normal quit while extracting waits for the cancelable ready callback.
            var quitResumed = false; calls = []
            driver.showDownloadDidStartExtractingUpdate()
            check(driver.cancelForTermination(completion: { quitResumed = true }))
            driver.showReady { calls.append($0) }
            check(calls == [.skip] && !quitResumed)
            driver.dismissUpdateInstallation(); check(quitResumed)
            // Resumed install registers cancellation before the base UI begins waiting.
            safe = true; calls = []; var delayedChoice: ((SPUUserUpdateChoice) -> Void)?
            let resumed = GuardedSparkleDriver(base: base, safety: { (safe, "busy") }, confirmReady: { true })
            resumed.presentInstallingUpdate(reply: { calls.append($0) }, present: { delayedChoice = $0 })
            var resumedQuit = false
            check(resumed.cancelForTermination(completion: { resumedQuit = true }))
            check(calls == [.skip] && !resumedQuit)
            delayedChoice?(.install); check(calls == [.skip])
            resumed.dismissUpdateInstallation(); check(resumedQuit)
            delayedChoice?(.install); check(calls == [.skip])
            check(!resumed.cancelForTermination(completion: {}))
            // The regular ready prompt can also be interrupted by an ordinary quit.
            weak var promptDriver: GuardedSparkleDriver?
            calls = []; var promptQuit = false
            let prompt = GuardedSparkleDriver(base: base, safety: { (true, "") }, confirmReady: {
                check(promptDriver!.cancelForTermination(completion: { promptQuit = true }))
                return true // A stale affirmative answer must not restart the canceled cycle.
            })
            promptDriver = prompt
            prompt.showReady { calls.append($0) }
            check(calls == [.skip] && !prompt.installRequested && !promptQuit)
            prompt.dismissUpdateInstallation(); check(promptQuit)
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("autorender-strict-settings-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let settings: [String: Any] = ["SURequireSignedFeed": true, "SUVerifyUpdateBeforeExtraction": true,
                "SUEnableAutomaticChecks": false, "SUAutomaticallyUpdate": false, "SUAllowsAutomaticUpdates": false,
                "SUSignedFeedFailureExpirationInterval": 0]
            func settingsBundle(_ values: [String: Any]) throws -> Bundle {
                let folder = temporary.appendingPathComponent(UUID().uuidString + ".bundle")
                try FileManager.default.createDirectory(at: folder.appendingPathComponent("Contents"), withIntermediateDirectories: true)
                var plist = values; plist["CFBundleIdentifier"] = "fr.robtech.autorender.strictsettings.fixture"
                let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                try data.write(to: folder.appendingPathComponent("Contents/Info.plist"))
                return Bundle(url: folder)!
            }
            let valid = try settingsBundle(settings)
            check(SoftwareUpdateCoordinator.hasStrictUpdateSettings(bundle: valid))
            for key in ["SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction", "SUEnableAutomaticChecks", "SUAutomaticallyUpdate", "SUAllowsAutomaticUpdates"] {
                var invalid = settings; invalid[key] = !(settings[key] as! Bool)
                let bundle = try settingsBundle(invalid)
                check(!SoftwareUpdateCoordinator.hasStrictUpdateSettings(bundle: bundle))
            }
            for value: Any in [1_728_000, false, "0"] {
                var invalid = settings; invalid["SUSignedFeedFailureExpirationInterval"] = value
                let bundle = try settingsBundle(invalid)
                check(!SoftwareUpdateCoordinator.hasStrictUpdateSettings(bundle: bundle))
            }
            var missing = settings; missing.removeValue(forKey: "SUSignedFeedFailureExpirationInterval")
            let missingBundle = try settingsBundle(missing)
            check(!SoftwareUpdateCoordinator.hasStrictUpdateSettings(bundle: missingBundle))
            print("PASS: \(checks) guarded driver/settings assertions; simulated callback plumbing, NOT real installer")
            return
        }
        guard ["probe", "probe_retry", "termination"].contains(args[1]), let host = Bundle(path: args[2]) else { fatalError("probe host required") }
        // A headless driver stops on appcast selection, before any installer/helper can launch.
        let base = NoUIUpdateDriver()
        guard let domain = host.bundleIdentifier, domain.hasPrefix("fr.robtech.autorender.headlessfixture.") else { fatalError("isolated fixture domain required") }
        let defaults = UserDefaults(suiteName: domain)
        defer {
            defaults?.removePersistentDomain(forName: domain)
            defaults?.synchronize()
        }
        var safetyAllowed = args[1] == "termination"
        let session = SoftwareUpdateSession(host: host, application: host, baseDriver: base, safety: { (safetyAllowed,"fixture fail closed") }, confirmReady: { args[1] == "termination" })
        if args[1] == "termination" {
            var checks = 0
            func check(_ value: @autoclosure () -> Bool) { checks += 1; precondition(value()) }
            var request = SoftwareUpdateQuitRequest()
            check(request.consume() == .updateOrUnknown)
            request.markUserRequest(); check(request.consume() == .explicitUser)
            check(request.consume() == .updateOrUnknown)
            request.markUserRequest(); request.clear(); check(request.consume() == .updateOrUnknown)
            var choices: [SPUUserUpdateChoice] = [], permissions: [Bool] = [], modelStopCalls = 0
            session.driver.showReady { choices.append($0) }
            check(choices == [.install] && session.driver.installRequested)
            safetyAllowed = false
            check(session.cancelForTermination { allowed in
                permissions.append(allowed)
                if allowed { modelStopCalls += 1 }
            })
            check(choices == [.install, .skip] && permissions.isEmpty)
            session.driver.dismissUpdateInstallation()
            for _ in 0..<1000 where permissions.isEmpty { try await Task.sleep(nanoseconds: 1_000_000) }
            check(permissions == [false] && modelStopCalls == 0)
            // No cycle remains: the next normal quit takes AppDelegate's ordinary stop path.
            let waitingAgain = session.cancelForTermination { allowed in permissions.append(allowed) }
            check(!waitingAgain)
            if !waitingAgain { modelStopCalls += 1 }
            check(modelStopCalls == 1 && permissions == [false])
            // A normal quit during download still resumes termination after cancellation.
            var downloadCancelled = false
            session.driver.showDownloadInitiated(cancellation: { downloadCancelled = true })
            check(session.cancelForTermination { allowed in permissions.append(allowed) })
            check(downloadCancelled)
            session.driver.dismissUpdateInstallation()
            for _ in 0..<1000 where permissions.count<2 { try await Task.sleep(nanoseconds: 1_000_000) }
            check(permissions == [false,true])
            // The same holds during extraction, without a requested installation.
            session.driver.showDownloadDidStartExtractingUpdate()
            check(session.cancelForTermination { allowed in permissions.append(allowed) })
            session.driver.showReady { choices.append($0) }
            check(choices.last == .skip)
            session.driver.dismissUpdateInstallation()
            for _ in 0..<1000 where permissions.count<3 { try await Task.sleep(nanoseconds: 1_000_000) }
            check(permissions == [false,true,true])
            // Safe installation handoff follows the normal termination path.
            safetyAllowed = true
            session.driver.showReady { choices.append($0) }
            check(session.driver.installRequested)
            check(!session.cancelForTermination { _ in preconditionFailure("Unexpected delay") })
            session.driver.cancelPreparedUpdate(); session.driver.dismissUpdateInstallation()
            // Explicit user intent cancels an unsafe installation but permits ordinary quit.
            safetyAllowed = true; session.driver.showReady { choices.append($0) }; safetyAllowed = false
            check(session.cancelForTermination(intent: .explicitUser) { allowed in permissions.append(allowed) })
            check(choices.last == .skip)
            session.driver.dismissUpdateInstallation()
            for _ in 0..<1000 where permissions.count<4 { try await Task.sleep(nanoseconds: 1_000_000) }
            check(permissions == [false,true,true,true])
            // A later request consumes no stale user marker and still quits normally.
            check(!session.cancelForTermination(intent: .updateOrUnknown) { _ in preconditionFailure("Stale intent") })
            print("PASS: \(checks) termination callback assertions; stop spy only, no AppKit/installer termination")
            return
        }
        precondition(!SoftwareUpdateCoordinator.isReleaseChannelConfigured(bundle: host))
        try session.updater.start()
        session.updater.checkForUpdates()
        for _ in 0..<300 where !base.finished { try await Task.sleep(nanoseconds: 100_000_000) }
        guard base.finished else { throw NSError(domain:"fixture",code:408) }
        var output: [String: Any] = ["found":base.found as Any? ?? NSNull(), "failure":base.failure as Any? ?? NSNull(), "installer_started":false]
        if args[1] == "probe_retry" {
            // Same process, updater and persistent domain: no reset between the two checks.
            let firstVersion = base.found
            for _ in 0..<300 where !session.updater.canCheckForUpdates { try await Task.sleep(nanoseconds: 100_000_000) }
            guard session.updater.canCheckForUpdates else { throw NSError(domain:"fixture",code:409) }
            base.finished = false; base.found = nil; base.failure = nil
            session.updater.checkForUpdates()
            for _ in 0..<300 where !base.finished { try await Task.sleep(nanoseconds: 100_000_000) }
            guard base.finished, firstVersion != nil, base.found == firstVersion else { throw NSError(domain:"fixture",code:410) }
            output["manual_retry_found"] = base.found
            output["same_updater_domain_preserved_between_checks"] = true
        }
        print(String(data: try JSONSerialization.data(withJSONObject: output), encoding:.utf8)!)
    }
}
