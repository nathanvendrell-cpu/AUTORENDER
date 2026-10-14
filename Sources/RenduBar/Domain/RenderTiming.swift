import Foundation
import CryptoKit

struct RenderProgress: Equatable, Codable {
    let completed: Int
    let total: Int
    init?(completed: Int, total: Int) {
        guard total > 0, completed >= 0, completed <= total else { return nil }
        self.completed = completed; self.total = total
    }
    var fraction: Double { Double(completed) / Double(total) }
    var countLabel: String { "\(completed)/\(total)" }
    var percentLabel: String { String(format: "%.1f %%", fraction * 100) }
}

enum RenderDate {
    private static let lock = NSLock()
    private static var cache: [String: Date] = [:]
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let iso = ISO8601DateFormatter()
    private static let local: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"; return f
    }()
    static func parseOptional(_ text: String?) -> Date? {
        guard let text else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let date = cache[text] { return date }
        let result = fractional.date(from: text) ?? iso.date(from: text) ?? local.date(from: text)
        if let result {
            if cache.count >= 8192 { cache.removeAll(keepingCapacity: true) }
            cache[text] = result
        }
        return result
    }
    static func parse(_ text: String?) -> Date { parseOptional(text) ?? .distantPast }
}

// Freshness describes a measurement, never process activity.
struct RenderTiming {
    let lastActivity: Date?
    let medianSeconds: Double?
    let sampledOutputsLastHour: Int?
    init(times: [String], at: Date?) {
        let dates = times.compactMap(RenderDate.parseOptional).filter { date in at.map { date <= $0 } ?? true }
        lastActivity = dates.max()
        let sorted = dates.sorted()
        let gaps = zip(sorted, sorted.dropFirst()).map { $1.timeIntervalSince($0) }.filter { $0 > 0 && $0.isFinite }.sorted()
        if gaps.isEmpty { medianSeconds = nil }
        else if gaps.count % 2 == 0 { medianSeconds = (gaps[gaps.count / 2 - 1] + gaps[gaps.count / 2]) / 2 }
        else { medianSeconds = gaps[gaps.count / 2] }
        sampledOutputsLastHour = at.map { reference in dates.filter { reference.timeIntervalSince($0) >= 0 && reference.timeIntervalSince($0) <= 3600 }.count }
    }
}

