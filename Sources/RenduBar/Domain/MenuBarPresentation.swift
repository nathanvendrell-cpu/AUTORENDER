import Foundation

/// Coverage of the required sources, supplied by the model without starting a probe.
enum MenuBarObservation: Equatable {
    case confirmed
    case refreshing
    case uncertain(String)
}

struct MenuBarPresentation: Equatable {
    let title: String
    let tooltip: String
    let accessibilityLabel: String
    let activeIDs: [String]
    let omittedTooltipJobs: Int

    /// Character bounds are explicit; physical menu-bar fit still needs native visual QA.
    static func make(snapshot: RenderCatalogSnapshot, observation: MenuBarObservation, now: Date,
                     titleLimit: Int = 40, tooltipJobLimit: Int = 12) -> Self {
        let limit = max(1, min(titleLimit, 96))
        let detailLimit = max(0, min(tooltipJobLimit, 40))
        let candidates = snapshot.jobs.filter(\.isDetectedActiveRender)
        let active = candidates.filter { job in
            guard let observed = job.observedAt else { return false }
            let age = now.timeIntervalSince(observed)
            return age.isFinite && age >= 0 && age <= (job.source.isShadow ? 120 : 30)
        }.sorted {
            let lhs = identity($0), rhs = identity($1)
            return lhs == rhs ? $0.id < $1.id : lhs < rhs
        }
        let coverage: MenuBarObservation
        if candidates.count != active.count || snapshot.stateCounts.running != active.count {
            coverage = .uncertain("Catalogue d’activité en cours de validation")
        } else { coverage = observation }
        let names = active.map(identity)
        var occurrences: [String: Int] = [:]
        let duplicated = Set(Dictionary(grouping: names, by: { $0 }).filter { $0.value.count > 1 }.keys)
        let labels = names.map { name -> String in
            guard duplicated.contains(name) else { return name }
            occurrences[name, default: 0] += 1
            return name + " #" + String(occurrences[name]!)
        }
        let marker: String
        let coverageText: String
        switch coverage {
        case .confirmed: marker = ""; coverageText = "Observation confirmée"
        case .refreshing: marker = "↻ "; coverageText = "Actualisation en cours · relevés encore valides seulement"
        case .uncertain(let reason): marker = "? "; coverageText = "Activité incertaine · " + clipped(clean(reason), 160)
        }
        let title: String
        if active.isEmpty {
            switch coverage {
            case .confirmed: title = clipped("Aucun actif détecté", limit)
            case .refreshing: title = clipped("Actualisation…", limit)
            case .uncertain: title = clipped("Activité incertaine", limit)
            }
        } else {
            let more = active.count > 1 ? " +" + String(active.count - 1) : ""
            let metrics = shortMetrics(active[0], now: now)
            let suffix = (metrics.isEmpty ? " · en cours" : " " + metrics) + more
            title = clipped(marker + clipped(labels[0], max(1, limit - marker.count - suffix.count)) + suffix, limit)
        }
        var lines = ["AUTORENDER · " + coverageText,
                     active.isEmpty && coverage == .confirmed ? "Aucun rendu actif sur les sources suivies." : "\(active.count) rendu(s) actif(s) détecté(s)"]
        if active.isEmpty && coverage != .confirmed { lines[1] = "L’absence de rendu n’est pas confirmée." }
        for (index, job) in active.prefix(detailLimit).enumerated() {
            var row = clipped(labels[index], 160) + " · " + (job.source.isShadow ? "PC" : "Mac")
            row += "\n  " + detailedProgress(job)
            row += " · " + (remaining(job, now: now) ?? "Temps restant non qualifié")
            if remaining(job, now: now) == nil, valid(job.rawProgress) == nil, valid(job.postProgress) == nil,
               let details = nativeActivityDetails(job, now: now) { row += " · " + details }
            if let observed = job.observedAt {
                row += " · relevé il y a " + String(max(0, Int(now.timeIntervalSince(observed)))) + " s"
            }
            lines.append(row)
        }
        let omitted = max(0, active.count - detailLimit)
        if omitted > 0 { lines.append("+\(omitted) autre(s) actif(s) · limite du détail : \(detailLimit)") }
        if active.count > 1 { lines.append("Progressions et temps par version ; aucun total agrégé.") }
        let tooltip = lines.joined(separator: "\n")
        return Self(title: title, tooltip: tooltip, accessibilityLabel: tooltip,
                    activeIDs: active.map(\.id), omittedTooltipJobs: omitted)
    }

    private static func identity(_ job: RenderDashboardJob) -> String {
        var parts: [String] = []
        for value in [job.projectTitle, job.workTitle, job.versionLabel ?? job.title] {
            let part = clean(value ?? "")
            if !part.isEmpty && parts.last != part { parts.append(part) }
        }
        return parts.isEmpty ? "Rendu sans nom" : parts.joined(separator: " · ")
    }
    private static func clean(_ value: String) -> String {
        let scalars = value.unicodeScalars.map { scalar -> String in
            if CharacterSet.controlCharacters.contains(scalar) || (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value) { return " " }
            return String(scalar)
        }.joined()
        return scalars.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
    private static func clipped(_ value: String, _ limit: Int) -> String {
        guard limit > 0 else { return "" }
        guard value.count > limit else { return value }
        guard limit > 2 else { return String(value.prefix(limit)) }
        let first = (limit - 1) * 2 / 3
        return String(value.prefix(first)) + "…" + String(value.suffix(limit - first - 1))
    }
    private static func valid(_ value: RenderProgress?) -> RenderProgress? {
        value.flatMap { RenderProgress(completed: $0.completed, total: $0.total) }
    }
    private static func percent(_ value: RenderProgress) -> String {
        // Exact integer tenths: no overflow and no rounded 100% before the counter reaches total.
        let numerator = UInt64(value.completed).multipliedFullWidth(by: 1000)
        let tenths = UInt64(value.total).dividingFullWidth(numerator).quotient
        return String(tenths / 10) + (tenths % 10 == 0 ? "" : "." + String(tenths % 10)) + "%"
    }
    private static func shortMetrics(_ job: RenderDashboardJob, now: Date, includeTime: Bool = true) -> String {
        let raw = valid(job.rawProgress), post = valid(job.postProgress)
        var result: String
        if job.postProgress != nil {
            result = "B" + (raw.map(percent) ?? "?") + " P" + (post.map(percent) ?? "?")
        } else { result = raw.map(percent) ?? "" }
        if includeTime, let time = remaining(job, now: now) { result += (result.isEmpty ? "" : " ") + time }
        else if raw == nil && post == nil { result = nativeActivityDetails(job, now: now) ?? "" }
        return result
    }
    private static func detailedProgress(_ job: RenderDashboardJob) -> String {
        let raw = valid(job.rawProgress), post = valid(job.postProgress)
        func detail(_ value: RenderProgress?) -> String {
            value.map { $0.countLabel + " (" + percent($0) + ")" } ?? "indéterminé"
        }
        if job.postProgress != nil { return "Brut " + detail(raw) + " · Post " + detail(post) }
        return "Progression " + detail(raw)
    }
    private static func nativeActivityDetails(_ job: RenderDashboardJob, now: Date) -> String? {
        guard job.isDetectedActiveRender else { return nil }
        var parts: [String] = []
        if let frame = job.currentFrame { parts.append("image \(frame)") }
        if let started = job.renderStartedAt {
            let seconds = now.timeIntervalSince(started)
            if seconds.isFinite && seconds >= 0 {
                let elapsed: String
                if seconds >= 365 * 86400 { elapsed = "≥365j" }
                else if seconds >= 86400 { elapsed = "\(Int(seconds / 86400))j" }
                else if seconds >= 3600 {
                    elapsed = "\(Int(seconds / 3600))h" + String(format: "%02d", Int(seconds / 60) % 60)
                } else if seconds >= 60 { elapsed = "\(Int(seconds / 60))min" }
                else { elapsed = "\(Int(seconds))s" }
                parts.append(elapsed + " éc.")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func remaining(_ job: RenderDashboardJob, now: Date) -> String? {
        guard job.isDetectedActiveRender else { return nil }
        // The model owns cadence/stage qualification. An absolute ETA decrements naturally.
        let seconds: Double
        if let eta = job.eta { seconds = eta.timeIntervalSince(now) }
        else if let estimate = job.estimatedRemainingSeconds, let observed = job.observedAt {
            let age = now.timeIntervalSince(observed)
            guard age.isFinite, age >= 0 else { return nil }
            seconds = estimate - age
        } else { return nil }
        guard seconds.isFinite, seconds > 0 else { return nil }
        if seconds < 60 { return "≈<1min" }
        if seconds >= 365 * 86400 { return "≥365j" }
        let minutes = Int(ceil(seconds / 60))
        if minutes < 60 { return "≈\(minutes)min" }
        if minutes < 1440 {
            let remainder = minutes % 60
            return "≈\(minutes / 60)h" + (remainder == 0 ? "" : String(format: "%02d", remainder))
        }
        return "≈\(Int(ceil(seconds / 86400)))j"
    }
}
