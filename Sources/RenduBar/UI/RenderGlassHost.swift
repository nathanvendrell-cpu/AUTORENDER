import AppKit
import SwiftUI

private struct RenderFocusKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var renderWindowFocused: Bool {
        get { self[RenderFocusKey.self] }
        set { self[RenderFocusKey.self] = newValue }
    }
}

private struct RenderWindowSurface: ViewModifier {
    @State private var focused = false
    func body(content: Content) -> some View {
        content.foregroundStyle(RenderStyle.ink).tint(RenderStyle.blue)
            .preferredColorScheme(.light)
            .background(RenderWindowBackdrop())
            .environment(\.renderWindowFocused, focused)
            .background(RenderFocusProbe { focused = $0 })
    }
}

private struct RenderWindowBackdrop: View {
    @Environment(\.renderWindowFocused) private var focused
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        Group {
            if RenderWindowFocusPolicy.opaqueBackground(focused: focused, reduceTransparency: reduceTransparency) {
                // Keep an alpha-1 foundation under the glass: focus must improve readability.
                shape.fill(RenderStyle.paper)
                    .overlay {
                        if #available(macOS 26, *), !reduceTransparency {
                            shape.fill(.clear).glassEffect(.regular.tint(.white.opacity(0.16)), in: shape)
                        }
                    }
                    .overlay { shape.strokeBorder(.white.opacity(0.24), lineWidth: 0.7).allowsHitTesting(false) }
            } else if #available(macOS 26, *) {
                shape.fill(.white.opacity(0.16))
                    .glassEffect(.clear.tint(.white.opacity(0.12)), in: shape)
            } else {
                RenderLegacyBackdrop().overlay(.white.opacity(0.16)).clipShape(shape)
            }
        }.allowsHitTesting(false)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: focused)
    }
}

private struct RenderLegacyBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private struct RenderGlassSurface: ViewModifier {
    let radius: CGFloat
    let shadow: CGFloat
    @Environment(\.renderWindowFocused) private var focused
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content.background {
            if reduceTransparency { shape.fill(RenderStyle.paper) }
            else if #available(macOS 26, *) {
                if focused { shape.fill(.clear).glassEffect(.clear.tint(.white.opacity(0.12)), in: shape) }
                else { shape.fill(.white.opacity(0.12)) }
            } else {
                if focused { shape.fill(.ultraThinMaterial) }
                else { shape.fill(.white.opacity(0.12)) }
            }
        }
        .overlay {
            shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.66), .white.opacity(0.10), .white.opacity(0.32)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8)
                .opacity(focused ? 1 : 0.4).allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(focused ? 0.16 : 0.04), radius: min(shadow, 8), y: 3)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: focused)
    }
}

extension View {
    func renderWindowSurface() -> some View { modifier(RenderWindowSurface()) }
    func renderGlass(radius: CGFloat = 24, shadow: CGFloat = 4) -> some View {
        modifier(RenderGlassSurface(radius: radius, shadow: shadow))
    }
}

private struct RenderFocusProbe: NSViewRepresentable {
    let changed: (Bool) -> Void
    func makeNSView(context: Context) -> Probe { let view = Probe(); view.changed = changed; return view }
    func updateNSView(_ view: Probe, context: Context) { view.changed = changed }
    final class Probe: NSView {
        var changed: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var last: Bool?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            clearObservers()
            guard let window else { return }
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                         NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in self?.refresh() })
            }
            for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: NSApp, queue: .main) { [weak self] _ in self?.refresh() })
            }
            refresh()
        }
        private func refresh() {
            let active = RenderWindowFocusPolicy.focused(applicationActive: NSApp.isActive,
                keyWindow: window?.isKeyWindow == true, mainWindow: window?.isMainWindow == true)
            guard active != last else { return }
            last = active
            DispatchQueue.main.async { [weak self] in self?.changed?(active) }
        }
        private func clearObservers() { observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll() }
        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}

final class RenderHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        appearance = RenderStyle.appearance
        window?.appearance = RenderStyle.appearance
    }
}

final class RenderHostingController<Content: View>: NSViewController {
    private let root: Content
    init(rootView: Content) { root = rootView; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("Unsupported coder") }
    override func loadView() {
        let hosting = RenderHostingView(rootView: root)
        // The NSWindow owns its user-chosen size; SwiftUI must not fit the
        // window back to the root view’s intrinsic/minimum size on launch.
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        view = hosting
    }
}
