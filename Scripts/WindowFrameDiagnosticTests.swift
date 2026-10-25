import Foundation
@main enum WindowFrameDiagnosticTests {
    @MainActor static func main() throws {
        var lines: [String] = []
        let recorder = WindowFrameDiagnostic(requested: true, canonical: true, startedAt: 100, write: { lines.append($0) })
        let frame = CGRect(x: -1200, y: 80, width: 520, height: 640)
        recorder.record(kind: .compact, action: .show, frame: frame, isVisible: true, isMiniaturized: false, at: 101)
        recorder.record(kind: .compact, action: .hide, frame: frame, isVisible: false, isMiniaturized: false, at: 102)
        recorder.record(kind: .compact, action: .show, frame: frame, at: 103)
        precondition(lines.count == 3)
        let first = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as! [String: Any]
        precondition(first["x"] as? Double == -1200 && first["w"] as? Double == 520)
        precondition(first["kind"] as? String == "compact" && first["action"] as? String == "show")
        precondition(first["isVisible"] as? Bool == true && first["isMiniaturized"] as? Bool == false)
        let hidden = try JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as! [String: Any]
        precondition(hidden["action"] as? String == "hide" && hidden["isVisible"] as? Bool == false)
        precondition(hidden["x"] as? Double == first["x"] as? Double && hidden["w"] as? Double == first["w"] as? Double)
        precondition(first["title"] == nil && first["path"] == nil && first["windowID"] == nil)
        for _ in 0..<40 { recorder.record(kind: .dashboard, action: .resize, frame: frame, at: 104) }
        precondition(lines.count == 24)
        let expired = WindowFrameDiagnostic(requested: true, canonical: true, startedAt: 100, write: { lines.append($0) })
        expired.record(kind: .dashboard, action: .show, frame: frame, at: 700)
        precondition(lines.count == 24)
        let disabled = WindowFrameDiagnostic(requested: false, canonical: true, startedAt: 100, write: { lines.append($0) })
        disabled.record(kind: .dashboard, action: .show, frame: frame, at: 101)
        let noncanonical = WindowFrameDiagnostic(requested: true, canonical: false, startedAt: 100, write: { lines.append($0) })
        noncanonical.record(kind: .dashboard, action: .show, frame: frame, at: 101)
        precondition(lines.count == 24)
        print("PASS window-frame diagnostic policy; synthetic CGRects only, no native windows")
    }
}
