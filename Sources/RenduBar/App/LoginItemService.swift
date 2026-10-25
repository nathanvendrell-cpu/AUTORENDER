import Foundation
#if !AUTORENDER_UI_HARNESS
import ServiceManagement
#endif

@MainActor enum LoginItemServiceFactory {
    static func make() -> any LoginItemService {
        #if AUTORENDER_UI_HARNESS
        return InertLoginItemService()
        #else
        return SystemLoginItemService()
        #endif
    }
}

@MainActor final class InertLoginItemService: LoginItemService {
    var state: LoginItemState { .unavailable }
    func register() throws { throw CocoaError(.featureUnsupported) }
    func unregister() throws { throw CocoaError(.featureUnsupported) }
    func openSettings() {}
}

#if !AUTORENDER_UI_HARNESS

@MainActor final class SystemLoginItemService: LoginItemService {
    private let service = SMAppService.mainApp
    var state: LoginItemState {
        switch service.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .disabled
        case .notFound: return .unavailable
        @unknown default: return .unavailable
        }
    }
    func register() throws { try service.register() }
    func unregister() throws { try service.unregister() }
    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}

#endif
