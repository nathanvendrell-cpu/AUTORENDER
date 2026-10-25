import Foundation
import CoreGraphics

/// Actual app-owned window frames only. No preferences, titles, paths or external window access.
@MainActor final class WindowFrameDiagnostic {
    enum Kind: String { case compact, dashboard }
    enum Action: String { case show, hide, move, resize, close, focusChange }
    private var enabled: Bool
    private let deadline: TimeInterval
    private var count = 0
    private let write: (String) -> Void
    init(requested: Bool, canonical: Bool, startedAt: TimeInterval,
         write: @escaping (String) -> Void = { StartupDiagnostic.writeJSONLine($0) }) {
        enabled = requested && canonical && startedAt.isFinite
        deadline = startedAt + 600
        self.write = write
    }
    func record(kind: Kind, action: Action, frame: CGRect, isVisible: Bool? = nil, isMiniaturized: Bool? = nil,
                level: Int? = nil, hidesOnDeactivate: Bool? = nil, isKey: Bool? = nil, appActive: Bool? = nil,
                at uptime: TimeInterval) {
        if !uptime.isFinite || uptime >= deadline || count >= 24 { enabled = false }
        guard enabled, [frame.origin.x, frame.origin.y, frame.width, frame.height].allSatisfy(\.isFinite),
              frame.width > 0, frame.height > 0 else { return }
        let payload: [String: Any] = ["event": "window-frame", "kind": kind.rawValue, "action": action.rawValue,
            "x": Double(frame.origin.x), "y": Double(frame.origin.y), "w": Double(frame.width), "h": Double(frame.height),
            "isVisible": isVisible.map { $0 as Any } ?? NSNull(),
            "isMiniaturized": isMiniaturized.map { $0 as Any } ?? NSNull(),
            "windowLevel": level.map { $0 as Any } ?? NSNull(),
            "hidesOnDeactivate": hidesOnDeactivate.map { $0 as Any } ?? NSNull(),
            "isKey": isKey.map { $0 as Any } ?? NSNull(),
            "appActive": appActive.map { $0 as Any } ?? NSNull(),
            "unit": "points", "proof": "Actual NSWindow frame and visibility state; visual acceptance unverified"]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return }
        count += 1; write(json)
        if count >= 24 { enabled = false }
    }
}
