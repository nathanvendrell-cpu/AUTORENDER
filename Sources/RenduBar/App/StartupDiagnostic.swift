import Foundation
import Darwin

/// Opt-in, callback-driven state evidence. Does not establish visual visibility or acceptance.
@MainActor final class StartupDiagnostic {
    private let deadline: TimeInterval
    private let write: (String) -> Void
    private var enabled: Bool
    private var count = 0
    private var previous: String?
    init(requested: Bool, canonical: Bool, startedAt: TimeInterval,
         write: @escaping (String) -> Void = { StartupDiagnostic.writeJSONLine($0) }) {
        enabled = requested && canonical && startedAt.isFinite
        deadline = startedAt + 90
        self.write = write
    }
    nonisolated static func writeJSONLine(_ text: String) {
        print(text)
        fflush(stdout)
    }
    func isRecording(at uptime: TimeInterval) -> Bool {
        if !uptime.isFinite || uptime >= deadline || count >= 10 { enabled = false }
        return enabled
    }
    func record(version: String, build: String, pid: Int32, assignedTitle: String,
                itemWidth: Double, buttonWidth: Double, observation: String,
                loginState: String, loginError: Bool, at uptime: TimeInterval) {
        guard isRecording(at: uptime) else { return }
        // A title may originate in project metadata. Withhold path-like content rather than leak it.
        let redact = assignedTitle.contains("/") || assignedTitle.contains("\\") || assignedTitle.contains("@") || assignedTitle.contains("~")
        var value: [String: Any] = ["event": "startup-state", "version": String(version.prefix(32)),
            "build": String(build.prefix(32)), "pid": pid, "titleRedacted": redact,
            "observation": observation, "loginState": loginState, "loginError": loginError,
            "proof": "AppKit state only; visual visibility and acceptance unverified"]
        value["assignedTitle"] = redact ? NSNull() : String(assignedTitle.prefix(128)) as Any
        value["itemWidthPoints"] = itemWidth.isFinite ? itemWidth as Any : NSNull()
        value["buttonWidthPoints"] = buttonWidth.isFinite ? buttonWidth as Any : NSNull()
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8), json != previous else { return }
        previous = json
        count += 1
        write(json)
        if count >= 10 { enabled = false }
    }
}
