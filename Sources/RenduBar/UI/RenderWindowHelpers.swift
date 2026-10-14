import SwiftUI

extension View {
    /// Native drag on the noninteractive identity region only. Popovers stay inert.
    @ViewBuilder
    func renderWindowDragRegion(enabled: Bool = true) -> some View {
        if #available(macOS 15.0, *), enabled {
            self.contentShape(Rectangle()).gesture(WindowDragGesture())
                .help("Déplacer la fenêtre")
        } else {
            self
        }
    }
}
