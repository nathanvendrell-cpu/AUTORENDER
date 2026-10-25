import Foundation

/// Explicit canonical startup request; absence of the flag never enables Shadow.
enum MacOnlyStartupPolicy {
    static func shouldApply(requested: Bool, canonical: Bool) -> Bool { requested && canonical }
    static func diagnostic(canonical: Bool, runtimeShadowEnabled: Bool, persistedShadowEnabled: Bool?) -> String? {
        let saved = persistedShadowEnabled == false
        let state = !canonical ? "rejected-noncanonical" : runtimeShadowEnabled ? "runtime-disable-failed" : saved ? "saved" : "runtime-only-persistence-failed"
        let value: [String: Any] = ["operation": "mac-only", "state": state,
            "canonical": canonical, "runtimeShadowMonitoringEnabled": runtimeShadowEnabled,
            "persistedShadowMonitoringEnabled": persistedShadowEnabled.map { $0 as Any } ?? NSNull()]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
