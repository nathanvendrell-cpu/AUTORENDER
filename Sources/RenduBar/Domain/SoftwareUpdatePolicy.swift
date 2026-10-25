import Foundation

enum SoftwareUpdateSafety: Equatable {
    case safe, busy, uncertain
}

enum SoftwareUpdatePolicy {
    enum Configuration: Equatable {
        case unconfigured
        case configured(feedURL: URL, publicEDKey: String)
    }

    // Structural validation only. The updater must still verify the downloaded signature.
    // No feed or signing key is supplied by this policy.
    static func configuration(feedURL: String?, publicEDKey: String?) -> Configuration {
        guard let feedURL, let publicEDKey,
              feedURL == feedURL.trimmingCharacters(in: .whitespacesAndNewlines),
              let parts = URLComponents(string: feedURL), parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty, !host.contains(where: { $0.isWhitespace }),
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              let url = parts.url,
              let key = Data(base64Encoded: publicEDKey), key.count == 32,
              key.base64EncodedString() == publicEDKey, key.contains(where: { $0 != 0 }) else {
            return .unconfigured
        }
        return .configured(feedURL: url, publicEDKey: publicEDKey)
    }

    static func permitsUpdate(currentBuild: String, candidateBuild: String) -> Bool {
        guard let current = integer(currentBuild), let candidate = integer(candidateBuild) else { return false }
        return candidate > current
    }

    static func permitsUpdate(currentVersion: String, currentBuild: String,
                              candidateVersion: String, candidateBuild: String) -> Bool {
        guard permitsUpdate(currentBuild: currentBuild, candidateBuild: candidateBuild),
              let current = version(currentVersion), let candidate = version(candidateVersion) else { return false }
        return candidate == current || current.lexicographicallyPrecedes(candidate)
    }

    private static func integer(_ text: String) -> UInt64? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return UInt64(text)
    }

    private static func version(_ text: String) -> [UInt64]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        let values = parts.compactMap { integer(String($0)) }
        guard values.count == parts.count else { return nil }
        return values + Array(repeating: 0, count: 3-values.count)
    }

    struct SourceEvidence {
        let online: Bool
        let stale: Bool
        let partial: Bool
        let observedAt: Date?
        let checkedAt: Date?
        let qualifiedActive: Bool
        let unattributedCandidate: Bool
    }

    enum ShadowScope {
        case required
        case confirmedUnconfigured(checkedAt: Date)
        case uncertain
    }

    struct SafetyEvidence {
        let monitoringEnabled: Bool
        let stopping: Bool
        let configurationReadable: Bool
        let refreshing: Bool
        let generationsConverged: Bool
        let native: SourceEvidence
        let shadow: SourceEvidence
        var shadowScope: ShadowScope = .required
    }

    struct SafetyAssessment: Equatable {
        let safety: SoftwareUpdateSafety
        let reason: String
    }

    // These windows match the existing native/Shadow observation contracts.
    // Safe means observed absence within those scopes, not a lock on future process creation.
    static func assess(_ evidence: SafetyEvidence, at now: Date) -> SafetyAssessment {
        guard evidence.monitoringEnabled, !evidence.stopping else {
            return SafetyAssessment(safety: .uncertain, reason: "Surveillance indisponible ou en arrêt")
        }
        guard evidence.configurationReadable else {
            return SafetyAssessment(safety: .uncertain, reason: "Configuration non vérifiée")
        }
        let nativeFresh = fresh(evidence.native, maximumAge: 30, at: now)
        let shadowFresh = fresh(evidence.shadow, maximumAge: 120, at: now)
        if (nativeFresh && evidence.native.qualifiedActive) || (shadowFresh && evidence.shadow.qualifiedActive) {
            return SafetyAssessment(safety: .busy, reason: "Rendu actif observé")
        }
        guard !evidence.refreshing, evidence.generationsConverged else {
            return SafetyAssessment(safety: .uncertain, reason: "Observation en cours de validation")
        }
        let shadowCovered:Bool
        switch evidence.shadowScope {
        case .required:
            shadowCovered=shadowFresh && !evidence.shadow.partial
        case .confirmedUnconfigured(let checked):
            let age=now.timeIntervalSince(checked)
            shadowCovered=age.isFinite && age>=0 && age<=30
                && !evidence.shadow.qualifiedActive && !evidence.shadow.unattributedCandidate
        case .uncertain:
            shadowCovered=false
        }
        guard nativeFresh, !evidence.native.partial, shadowCovered else {
            return SafetyAssessment(safety: .uncertain, reason: "Couverture périmée ou incomplète")
        }
        guard !evidence.native.unattributedCandidate, !evidence.shadow.unattributedCandidate else {
            return SafetyAssessment(safety: .uncertain, reason: "Processus candidat non attribué")
        }
        return SafetyAssessment(safety: .safe, reason: "Absence de rendu observée sur les périmètres couverts")
    }

    private static func fresh(_ source: SourceEvidence, maximumAge: TimeInterval, at now: Date) -> Bool {
        guard source.online, !source.stale, let observed = source.observedAt, let checked = source.checkedAt else { return false }
        return [observed, checked].allSatisfy {
            let age = now.timeIntervalSince($0)
            return age.isFinite && age >= 0 && age <= maximumAge
        }
    }
}
