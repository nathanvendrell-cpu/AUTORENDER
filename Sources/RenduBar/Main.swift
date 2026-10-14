import AppKit

#if !AUTORENDER_UI_HARNESS
@main
enum RenduBarMain {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = RenduAppDelegate()
        application.delegate = delegate
        application.run()
    }
}
#endif
