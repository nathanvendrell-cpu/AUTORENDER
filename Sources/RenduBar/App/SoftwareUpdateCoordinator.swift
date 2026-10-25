import AppKit
import Security

enum SoftwareUpdateQuitIntent { case explicitUser, updateOrUnknown }
struct SoftwareUpdateQuitRequest {
    private var intent: SoftwareUpdateQuitIntent = .updateOrUnknown
    mutating func markUserRequest() { intent = .explicitUser }
    mutating func consume() -> SoftwareUpdateQuitIntent {
        defer { intent = .updateOrUnknown }
        return intent
    }
    mutating func clear() { intent = .updateOrUnknown }
}
#if canImport(Sparkle)
import Sparkle

/// No timer or renderer probe here. The owner supplies a current, fail-closed safety verdict.
@MainActor
final class SoftwareUpdateSession: NSObject, SPUUpdaterDelegate {
    typealias Safety = () -> (allowed: Bool, reason: String)
    let safety: Safety
    let host: Bundle
    let driver: GuardedSparkleDriver
    private(set) var updater: SPUUpdater!
    private(set) var lastRefusal: String?

    init(host: Bundle, application: Bundle, baseDriver: SPUUserDriver,
         safety: @escaping Safety, confirmReady: @escaping () -> Bool, reportRefusal: @escaping (String) -> Void = { _ in }) {
        self.safety = safety; self.host = host
        driver = GuardedSparkleDriver(base: baseDriver, safety: safety, confirmReady: confirmReady, reportRefusal: reportRefusal)
        super.init()
        updater = SPUUpdater(hostBundle: host, applicationBundle: application, userDriver: driver, delegate: self)
    }
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        // The release configuration disallows scheduled checks, downloading and installation.
        guard updateCheck == .updates else { throw refusal("Vérification automatique désactivée.") }
    }
    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }
    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        guard let currentBuild = host.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              let currentVersion = host.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              SoftwareUpdatePolicy.permitsUpdate(currentVersion: currentVersion, currentBuild: currentBuild,
                  candidateVersion: item.displayVersionString, candidateBuild: item.versionString),
              !item.isInformationOnlyUpdate, item.installationType == "application" else {
            throw refusal("Ce canal accepte uniquement les mises à jour de l’application.")
        }
    }
    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        let verdict = safety()
        guard verdict.allowed else {
            lastRefusal = verdict.reason
            driver.cancelPreparedUpdate()
            return false // Sparkle 2.10 vetoes stage 2 here, before replacement.
        }
        return true
    }
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        let verdict = safety()
        if !verdict.allowed {
            lastRefusal = verdict.reason
            driver.cancelPreparedUpdate()
            return true // Never retain or invoke a deferred install handler.
        }
        return false
    }
    /// Called before model.stop(). Normal quitting remains possible after cancellation.
    func cancelForTermination(intent: SoftwareUpdateQuitIntent = .updateOrUnknown, completion: @escaping (_ allowTermination: Bool) -> Void) -> Bool {
        let verdict = safety()
        if driver.installRequested && verdict.allowed && intent != .explicitUser { return false }
        // Capture intent before cancellation clears installRequested. Refuse only this
        // unsafe installation-related termination; the next ordinary quit can proceed.
        let refuseThisTermination = driver.installRequested && !verdict.allowed && intent != .explicitUser
        if refuseThisTermination { lastRefusal = verdict.reason }
        let waiting = driver.cancelForTermination {
            Task { @MainActor in completion(!refuseThisTermination) }
        }
        if refuseThisTermination && !waiting {
            Task { @MainActor in completion(false) }
            return true
        }
        return waiting
    }
    private func refusal(_ message: String) -> NSError {
        NSError(domain: "fr.robtech.autorender.update", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// Uses Sparkle's own UI and engine, but consumes every ready-stage choice through one guard.
/// Dismiss at this stage is intentionally mapped to skip: skip cancels without blacklisting.
@MainActor
final class GuardedSparkleDriver: NSObject, SPUUserDriver {
    let base: SPUUserDriver
    let safety: SoftwareUpdateSession.Safety
    let confirmReady: () -> Bool
    let reportRefusal: (String) -> Void
    private enum PreparedContext { case ready, resumedInstalling }
    private var preparedContext: PreparedContext?
    private var choiceGeneration: UInt64 = 0
    private var preparedReply: ((SPUUserUpdateChoice) -> Void)?
    private var downloadCancellation: (() -> Void)?
    private var extractionInFlight = false
    private var cancellationInFlight = false
    private var quitCompletion: (() -> Void)?
    private(set) var installRequested = false
    private(set) var refusalReason: String?
    init(base: SPUUserDriver, safety: @escaping SoftwareUpdateSession.Safety, confirmReady: @escaping () -> Bool, reportRefusal: @escaping (String) -> Void = { _ in }) {
        self.base = base; self.safety = safety; self.confirmReady = confirmReady; self.reportRefusal = reportRefusal
    }
    func cancelPreparedUpdate() {
        installRequested = false
        choiceGeneration &+= 1 // Invalidate UI answers captured before this cancellation.
        let reply = preparedReply; preparedReply = nil
        if let reply {
            cancellationInFlight = true
            // ready: cancel without blacklisting. resumedInstalling/showUpdateFound: Sparkle
            // also records a skip; its next explicit manual check clears that skipped version.
            reply(.skip)
        }
    }
    func cancelForTermination(completion: @escaping () -> Void) -> Bool {
        if preparedReply != nil {
            quitCompletion = completion
            cancelPreparedUpdate()
            return true
        }
        if let cancel = downloadCancellation {
            quitCompletion = completion; downloadCancellation = nil; choiceGeneration &+= 1; cancel()
            return true
        }
        if extractionInFlight || cancellationInFlight {
            // Do not quit with a prepared installer watching the application's exit.
            // Finish preparation, immediately send skip, and resume ordinary termination.
            quitCompletion = completion
            return true
        }
        return false
    }
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        downloadCancellation = cancellation
        base.showUserInitiatedUpdateCheck(cancellation: cancellation)
    }
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        downloadCancellation = nil
        if state.stage == .installing {
            presentInstallingUpdate(reply: reply) { [base] respond in
                base.showUpdateFound(with: appcastItem, state: state, reply: respond)
            }
        } else {
            let generation = choiceGeneration
            base.showUpdateFound(with: appcastItem, state: state) { [weak self] choice in
                guard let self, generation == self.choiceGeneration else { return }
                reply(choice) // Found-stage dismiss/skip keep their distinct Sparkle meanings.
            }
        }
    }
    /// Registers the cancellation before any resumed-installation UI can wait for the user.
    func presentInstallingUpdate(reply: @escaping (SPUUserUpdateChoice) -> Void,
                                 present: (@escaping (SPUUserUpdateChoice) -> Void) -> Void) {
        let generation = beginPrepared(reply: reply, context: .resumedInstalling)
        let verdict = safety()
        guard verdict.allowed, quitCompletion == nil else {
            if !verdict.allowed { refusalReason = verdict.reason }
            cancelPreparedUpdate(); return
        }
        present { [weak self] choice in
            self?.acceptPreparedChoice(generation: generation, wantsInstall: choice == .install)
        }
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) { base.showUpdateReleaseNotes(with: downloadData) }
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) { base.showUpdateReleaseNotesFailedToDownloadWithError(error) }
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        downloadCancellation = nil; base.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement)
    }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        base.showUpdaterError(error, acknowledgement: acknowledgement)
    }
    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        downloadCancellation = cancellation; base.showDownloadInitiated(cancellation: cancellation)
    }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) { base.showDownloadDidReceiveExpectedContentLength(expectedContentLength) }
    func showDownloadDidReceiveData(ofLength length: UInt64) { base.showDownloadDidReceiveData(ofLength: length) }
    func showDownloadDidStartExtractingUpdate() {
        downloadCancellation = nil; extractionInFlight = true; base.showDownloadDidStartExtractingUpdate()
    }
    func showExtractionReceivedProgress(_ progress: Double) { base.showExtractionReceivedProgress(progress) }
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let generation = beginPrepared(reply: reply, context: .ready)
        let verdict = safety()
        guard verdict.allowed, quitCompletion == nil else {
            if !verdict.allowed { refusalReason = verdict.reason }
            cancelPreparedUpdate(); return
        }
        acceptPreparedChoice(generation: generation, wantsInstall: confirmReady())
    }
    private func beginPrepared(reply: @escaping (SPUUserUpdateChoice) -> Void, context: PreparedContext) -> UInt64 {
        extractionInFlight = false
        choiceGeneration &+= 1
        preparedContext = context; preparedReply = reply
        return choiceGeneration
    }
    private func acceptPreparedChoice(generation: UInt64, wantsInstall: Bool) {
        guard generation == choiceGeneration, let reply = preparedReply, !cancellationInFlight else { return }
        let verdict = safety() // Re-read after the user has spent time reading notes/confirming.
        guard wantsInstall, verdict.allowed, quitCompletion == nil else {
            if !verdict.allowed { refusalReason = verdict.reason }
            cancelPreparedUpdate(); return
        }
        installRequested = true
        reply(.install)
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        let generation = choiceGeneration
        base.showInstallingUpdate(withApplicationTerminated: applicationTerminated) { [weak self] in
            guard let self, generation == self.choiceGeneration, self.installRequested else { return }
            if self.safety().allowed { retryTerminatingApplication() } else { self.cancelPreparedUpdate() }
        }
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        base.showUpdateInstalledAndRelaunched(relaunched, acknowledgement: acknowledgement)
    }
    func dismissUpdateInstallation() {
        choiceGeneration &+= 1; preparedContext = nil
        preparedReply = nil; downloadCancellation = nil; extractionInFlight = false; cancellationInFlight = false; installRequested = false
        base.dismissUpdateInstallation()
        let finish = quitCompletion; quitCompletion = nil
        if let finish { finish() } else if let refusalReason { self.refusalReason = nil; reportRefusal(refusalReason) }
    }
    func showUpdateInFocus() { base.showUpdateInFocus?() }
}
#endif

@MainActor
final class SoftwareUpdateCoordinator {
    private let safety: () -> (allowed: Bool, reason: String)
    #if canImport(Sparkle)
    private var session: SoftwareUpdateSession?
    #endif
    init(safety: @escaping () -> (allowed: Bool, reason: String)) { self.safety = safety }
    func checkForUpdates() {
        guard Self.isReleaseChannelConfigured(bundle: .main) else {
            showMessage("Canal de mise à jour non configuré", "Aucun canal signé n’est activé pour cette installation.")
            return
        }
        #if canImport(Sparkle)
        if session == nil {
            let host = Bundle.main
            let base = SPUStandardUserDriver(hostBundle: host, delegate: nil)
            let created = SoftwareUpdateSession(host: host, application: host, baseDriver: base, safety: safety, confirmReady: {
                let alert = NSAlert()
                alert.messageText = "Installer la mise à jour et relancer AUTORENDER ?"
                alert.informativeText = "Les notes et la version sont présentées par Sparkle. L’installation sera annulée si un rendu est actif ou si son état est incertain."
                alert.addButton(withTitle: "Installer et relancer")
                alert.addButton(withTitle: "Plus tard")
                return alert.runModal() == .alertFirstButtonReturn
            }, reportRefusal: { [weak self] reason in
                self?.showMessage("Mise à jour reportée", reason)
            })
            do { try created.updater.start(); session = created }
            catch { showMessage("Mise à jour indisponible", error.localizedDescription); return }
        }
        guard let updater = session?.updater, updater.canCheckForUpdates else { return }
        updater.checkForUpdates()
        #else
        showMessage("Moteur de mise à jour indisponible", "Cette construction ne contient pas Sparkle.")
        #endif
    }
    func cancelForTermination(intent: SoftwareUpdateQuitIntent = .updateOrUnknown, completion: @escaping (_ allowTermination: Bool) -> Void) -> Bool {
        #if canImport(Sparkle)
        return session?.cancelForTermination(intent: intent, completion: completion) ?? false
        #else
        return false
        #endif
    }
    static func isReleaseChannelConfigured(bundle: Bundle) -> Bool {
        guard bundle.bundleIdentifier == "fr.robtech.rendubar", hasStrictUpdateSettings(bundle: bundle) else { return false }
        let configuration = SoftwareUpdatePolicy.configuration(
            feedURL: bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            publicEDKey: bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)
        guard case .configured = configuration,
              let expectedTeam = bundle.object(forInfoDictionaryKey: "AUTORENDERUpdateTeamID") as? String,
              expectedTeam.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else { return false }
        var requirement: SecRequirement?
        let developerID = "anchor apple generic and identifier \"fr.robtech.rendubar\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"\(expectedTeam)\""
        guard SecRequirementCreateWithString(developerID as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle.bundleURL as CFURL, [], &code) == errSecSuccess,
              let code, SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any],
              values[kSecCodeInfoTeamIdentifier as String] as? String == expectedTeam,
              let flags = values[kSecCodeInfoFlags as String] as? UInt32,
              flags & 0x2 == 0 else { return false } // Ad-hoc builds never activate a public feed.
        return true
    }
    static func hasStrictUpdateSettings(bundle: Bundle) -> Bool {
        let settings = ["SURequireSignedFeed": true, "SUVerifyUpdateBeforeExtraction": true,
                        "SUEnableAutomaticChecks": false, "SUAutomaticallyUpdate": false,
                        "SUAllowsAutomaticUpdates": false]
        for (key, expected) in settings {
            guard let value = bundle.object(forInfoDictionaryKey: key) as? NSNumber,
                  CFGetTypeID(value) == CFBooleanGetTypeID(), value.boolValue == expected else { return false }
        }
        guard let interval = bundle.object(forInfoDictionaryKey: "SUSignedFeedFailureExpirationInterval") as? NSNumber,
              CFGetTypeID(interval) != CFBooleanGetTypeID(), interval.doubleValue == 0 else { return false }
        return true
    }
    private func showMessage(_ title: String, _ detail: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail
        alert.addButton(withTitle: "OK"); alert.runModal()
    }
}
