import AppKit
import SwiftUI

enum RenderStyle {
    static let blue = Color(red: 0.29, green: 0.57, blue: 1)
    static let ink = Color(white: 0.06)
    static let secondary = Color(white: 0.22)
    static let paper = Color(white: 0.94)
    static let appearance = NSAppearance(named: .aqua)
}

enum RenderStatus {
    static func label(_ job: RenderDashboardJob) -> String {
        guard job.isFresh, !job.retainedHistorical else { return "Dernier relevé" }
        switch job.activity {
        case .running: return "En cours"
        case .stopped, .resumeRequired: return "À reprendre"
        case .countsReached: return "Terminé"
        case .unknown: return "Indéterminé"
        }
    }
}
