import SwiftUI

/// Makes the window draggable by its background and keeps it exactly as tall as its content.
/// The window is not user-resizable, so this is what resizes it when a section opens.
struct WindowConfigurator: NSViewRepresentable {
    let contentHeight: CGFloat
    let width: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.isMovableByWindowBackground = true
            window.titlebarAppearsTransparent = true
            window.styleMask.remove(.resizable)
            window.standardWindowButton(.zoomButton)?.isEnabled = false
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let latest = context.coordinator
        latest.height = contentHeight
        guard contentHeight > 0 else { return }
        fit(nsView, to: latest)
        // Heights reported while a section is animating open are part-way values, so take the
        // settled one shortly after as well.
        guard !latest.checking else { return }
        latest.checking = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            latest.checking = false
            fit(nsView, to: latest)
        }
    }

    func makeCoordinator() -> Latest { Latest() }

    final class Latest {
        var height: CGFloat = 0
        var checking = false
    }

    private func fit(_ nsView: NSView, to latest: Latest) {
        DispatchQueue.main.async {
            guard let window = nsView.window, latest.height > 0,
                  abs(window.frame.height - latest.height) > 0.5 else { return }
            // Grow downwards from the title bar rather than from the bottom edge.
            var frame = window.frame
            frame.origin.y += frame.height - latest.height
            frame.size = NSSize(width: width, height: latest.height)
            window.setFrame(frame, display: true, animate: false)
        }
    }
}

/// Answers the Edit ▸ Paste command (⌘V) for the window when no text field has focus, so files
/// copied in Finder can be pasted straight into the patcher.
struct PasteCatcher: NSViewRepresentable {
    let onPaste: () -> Void

    func makeNSView(context: Context) -> PasteView {
        let view = PasteView()
        view.onPaste = onPaste
        DispatchQueue.main.async { view.window?.initialFirstResponder = view; view.window?.makeFirstResponder(view) }
        return view
    }
    func updateNSView(_ nsView: PasteView, context: Context) { nsView.onPaste = onPaste }

    final class PasteView: NSView {
        var onPaste: () -> Void = {}
        override var acceptsFirstResponder: Bool { true }
        @objc func paste(_ sender: Any?) { onPaste() }
        override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool { true }
        override func responds(to aSelector: Selector!) -> Bool {
            if aSelector == #selector(paste(_:)) {
                return NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            }
            return super.responds(to: aSelector)
        }
    }
}

/// Environment-variable hooks for screenshots and testing. They do nothing unless set.
///   GPTKPATCHER_CROSSOVER=<path>  GPTKPATCHER_DMG=<path>  GPTKPATCHER_OUTPUT=<folder>
///   GPTKPATCHER_PASTE=1  GPTKPATCHER_AUTOPATCH=1  GPTKPATCHER_OPEN_SETTINGS=1  GPTKPATCHER_SKIP_NOTICE=1
///   GPTKPATCHER_APPEARANCE=light|dark
enum DebugHooks {
    @MainActor
    static func apply(to engine: PatchEngine) {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if let appearance = env["GPTKPATCHER_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
        }
        if let path = env["GPTKPATCHER_CROSSOVER"] { engine.setCrossOver(URL(fileURLWithPath: path)) }
        if env["GPTKPATCHER_PASTE"] == "1" { engine.pasteFromPasteboard() }
        if let path = env["GPTKPATCHER_OUTPUT"] { engine.useTemporaryOutputFolder(URL(fileURLWithPath: path)) }
        if let path = env["GPTKPATCHER_DMG"] {
            engine.importToolkit(from: URL(fileURLWithPath: path))
            if env["GPTKPATCHER_AUTOPATCH"] == "1" {
                Task { @MainActor in
                    let deadline = Date().addingTimeInterval(120)
                    while !engine.isReady, Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
                    if engine.isReady { engine.patch() }
                }
            }
        }
        #endif
    }
}
