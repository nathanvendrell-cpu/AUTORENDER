import Foundation
import Combine

enum LoginItemState: Equatable { case disabled, enabled, requiresApproval, unavailable }

@MainActor protocol LoginItemService {
    var state: LoginItemState { get }
    func register() throws
    func unregister() throws
    func openSettings()
}

/// Reads the service itself; no separate persisted Boolean can drift from macOS.
@MainActor final class LoginItemController: ObservableObject {
    @Published private(set) var state: LoginItemState = .unavailable
    @Published private(set) var error: String?
    private let service: any LoginItemService
    let mayRegister: Bool
    init(service: any LoginItemService, mayRegister: Bool) {
        self.service = service; self.mayRegister = mayRegister
        refresh()
    }
    var label: String {
        switch state {
        case .enabled: return "Ouverture de session : activée"
        case .requiresApproval: return "Ouverture de session : approbation requise"
        case .disabled: return "Ouverture de session : désactivée"
        case .unavailable: return "Ouverture de session : indisponible"
        }
    }
    func refresh() { state = service.state }
    func enable() {
        guard mayRegister else {
            error = "Activer depuis l’installation canonique AUTORENDER, après validation de l’installation."
            refresh(); return
        }
        refresh()
        if state == .enabled { error = nil; return }
        perform { try service.register() }
    }
    func disable() {
        guard mayRegister else {
            error = "Modifier depuis l’installation canonique AUTORENDER."
            refresh(); return
        }
        refresh()
        if state == .disabled { error = nil; return }
        perform { try service.unregister() }
    }
    func openSettings() { service.openSettings(); refresh() }
    private func perform(_ operation: () throws -> Void) {
        error = nil
        do { try operation() } catch { self.error = error.localizedDescription }
        refresh()
    }
    static func isCanonical(bundleURL: URL, homeURL: URL, bundleIdentifier: String?) -> Bool {
        guard bundleIdentifier == "fr.robtech.rendubar" else { return false }
        return bundleURL.standardizedFileURL == homeURL.appendingPathComponent("Applications/AUTORENDER.app").standardizedFileURL
            && bundleURL.resolvingSymlinksInPath() == bundleURL.standardizedFileURL
    }
}
