import Foundation

/// Window-local focus; being in the application alone never activates every window.
enum RenderWindowFocusPolicy {
    static func focused(applicationActive: Bool, keyWindow: Bool, mainWindow: Bool) -> Bool {
        applicationActive && (keyWindow || mainWindow)
    }
    static func opaqueBackground(focused: Bool, reduceTransparency: Bool) -> Bool {
        focused || reduceTransparency
    }
}
