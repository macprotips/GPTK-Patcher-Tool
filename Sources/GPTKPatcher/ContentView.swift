import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable private var engine = PatchEngine.shared
    @State private var showLog = false
    @State private var showWhatChanges = false
    @State private var showSupportNotice = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let width: CGFloat = 520

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 22)
            if case .idle = engine.phase { modePicker.padding(.bottom, 28) }
            else if case .cancelled = engine.phase { modePicker.padding(.bottom, 28) }
            else { Color.clear.frame(height: 0).padding(.bottom, 12) }

            Group {
                switch engine.phase {
                case .idle, .cancelled: form
                case .running(let step): progress(step)
                case .done(let url): success(url)
                case .failed(let failure): failed(failure)
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: engine.phase)
        }
        .padding(.horizontal, 30)
        .padding(.top, 26)
        .padding(.bottom, 26)
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)
        .background(WindowConfigurator())
        .background(PasteCatcher { engine.pasteFromPasteboard() })
        .sheet(isPresented: $showLog) { LogSheet(lines: engine.logLines) }
        .sheet(isPresented: $showSupportNotice) { SupportNoticeSheet() }
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            engine.refreshToolkits()
            engine.refreshPatchedApps()
            DebugHooks.apply(to: engine)
        }

        .task {
            // Presented after the window is on screen; a sheet requested earlier can be dropped.
            try? await Task.sleep(for: .milliseconds(250))
            if ProcessInfo.processInfo.environment["GPTKPATCHER_SKIP_NOTICE"] != "1" { showSupportNotice = true }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("GPTK Patcher Tool")
                .font(.title2.weight(.semibold))
            Text(engine.mode == .copy
                 ? "Update the Game Porting Toolkit in a copy of CrossOver."
                 : "Update the Game Porting Toolkit in your CrossOver.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var modePicker: some View {
        Picker("Mode", selection: $engine.mode) {
            Text("Duplicate CrossOver").tag(PatchMode.copy)
            Text("Patch Existing").tag(PatchMode.inPlace)
        }
        .pickerStyle(.segmented)
        .controlSize(.regular)
        .labelsHidden()
        .frame(width: 280)
        // No .help here: a segmented picker shows one tooltip for the whole control, which would
        // describe the wrong segment half the time. The subtitle above states the current mode.
    }

    // MARK: Idle form

    private var form: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                FileTile(label: "CrossOver", prompt: "Drop CrossOver.app here",
                         contentType: .applicationBundle, fileExtension: "app",
                         url: engine.crossOverURL, status: engine.crossOverStatus,
                         onPick: { engine.route($0) }, onClear: engine.clearCrossOver)
                ToolkitTile(engine: engine)
            }

            if engine.mode == .copy {
                destinationRow.padding(.top, 24)
            }

            if showsOutputSection {
                if engine.mode == .copy { Divider().padding(.vertical, 18) }
                outputSection.padding(.top, engine.mode == .copy ? 0 : 24)
            }

            actionBar.padding(.top, 18)
        }
    }

    /// True once there is either a result to preview or an app that has already been patched.
    private var showsPlannedOutput: Bool {
        engine.mode == .copy && engine.crossOver != nil && engine.selectedToolkit != nil
    }
    private var showsOutputSection: Bool { showsPlannedOutput || !engine.patchedApps.isEmpty }

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(showsPlannedOutput ? "Output" : "Patched")
            VStack(spacing: 0) {
                if showsPlannedOutput {
                    PlannedOutputRow(name: engine.outputName, sourceIcon: engine.crossOverURL)
                }
                ForEach(Array(engine.patchedApps.enumerated()), id: \.element.id) { index, app in
                    if index > 0 || showsPlannedOutput { Divider().padding(.leading, 14) }
                    PatchedAppRow(app: app, autoOpenSettings: index == 0 && ProcessInfo.processInfo.environment["GPTKPATCHER_OPEN_SETTINGS"] == "1", onForget: {
                        PatchedAppRegistry.forget(app.url)
                        engine.refreshPatchedApps()
                    })
                }
            }
            .modifier(InputTileChrome(targeted: false, isEmpty: false, isError: false, cornerRadius: 10))
        }
    }

    private var destinationRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Save patched copy to")
            HStack(spacing: 10) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text(destinationText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(destinationText)
                Spacer(minLength: 8)
                Button("Change…", action: chooseFolder)
                    .controlSize(.small)
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .frame(height: 38)
            .modifier(InputTileChrome(targeted: false, isEmpty: false, isError: false, cornerRadius: 10))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Save patched copy to \(destinationText)")
        }
    }

    /// The folder alone until both inputs are chosen; the full path once the name is real.
    private var destinationText: String {
        let url = showsPlannedOutput ? engine.outputURL : engine.outputFolder
        return url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            whatChangesLink
            if case .cancelled = engine.phase {
                Text("Patch cancelled. Nothing was changed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Patch CrossOver", action: engine.patch)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!engine.isReady)
        }
    }

    private var whatChangesLink: some View {
        Button {
            showWhatChanges.toggle()
        } label: {
            HStack(spacing: 3) {
                Text("What changes?")
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
        }
        .buttonStyle(.link)
        .font(.callout)
        .popover(isPresented: $showWhatChanges, arrowEdge: .top) { WhatChangesPopover(mode: engine.mode) }
    }

    // MARK: Running

    private func progress(_ current: PatchStep) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            Text("Patching CrossOver…")
                .font(.headline)
                .padding(.bottom, 4)
            Text(current == .verifying
                 ? "If macOS asks whether to open CrossOver, click Open. CrossOver will open; answer any prompt it shows, and it will be quit for you after a few seconds."
                 : " ")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 10)
            let sequence = PatchStep.sequence(for: engine.mode)
            let position = sequence.firstIndex(of: current) ?? 0
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(sequence.enumerated()), id: \.element.rawValue) { index, step in
                    HStack(spacing: 10) {
                        Group {
                            if index < position {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            } else if index == position {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "circle").foregroundStyle(.quaternary)
                            }
                        }
                        .frame(width: 18, height: 18)
                        Text(step.title(for: engine.mode))
                            .foregroundStyle(index <= position ? .primary : .secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(index < position ? "done" : index == position ? "in progress" : "pending")
                }
            }
            Spacer()
            HStack {
                Text(engine.logLines.last ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Cancel", action: engine.cancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .frame(height: 300)
    }

    // MARK: Done

    private func success(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.green)
                Text("CrossOver patched successfully")
                    .font(.headline)
            }
            .padding(.bottom, 14)
            Text(engine.mode == .copy ? "Patched copy created at" : "Patched and renamed to")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(.subheadline)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
                .padding(.top, 2)
            Text(engine.mode == .copy
                 ? "Open it like any other app. Your original CrossOver was not changed."
                 : "The stock toolkit was kept as apple_gptk.stock inside the app.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 12)
            Spacer()
            HStack {
                Spacer()
                Button("Done", action: engine.reset)
                    .keyboardShortcut(.cancelAction)
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(height: 300)
    }

    // MARK: Failed

    private func failed(_ failure: Failure) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.orange)
                Text(failure.title)
                    .font(.headline)
            }
            .padding(.bottom, 12)
            Text(failure.message)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Text(engine.mode == .copy
                 ? "Nothing was left half-patched: any unfinished copy was removed."
                 : "The app was put back the way it was.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 10)
            Spacer()
            HStack {
                Button("Details…") { showLog = true }
                Spacer()
                Button("Try Again", action: engine.reset)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(height: 300)
    }

    // MARK: Helpers

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = engine.outputFolder
        panel.prompt = "Choose"
        panel.message = "Choose where to save the patched copy of CrossOver."
        if panel.runModal() == .OK, let url = panel.url { engine.outputFolder = url }
    }
}

// MARK: - Supporting views

private struct WhatChangesPopover: View {
    let mode: PatchMode

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What patching does").font(.headline)
            if mode == .copy {
                bullet("Duplicates CrossOver.app. On an APFS disk the duplicate shares storage with the original until files change, so it is quick and takes little space.")
            } else {
                bullet("Modifies the selected CrossOver.app directly and adds the toolkit version to its name. Quit CrossOver before patching it.")
            }
            bullet("Replaces the app's built-in D3DMetal with the version from the toolkit. The original is kept next to it as apple_gptk.stock, so the change can be undone.")
            bullet("Adds the nvngx.dll that games with DLSS look for, and turns DLSS to MetalFX on for every bottle the app launches.")
            bullet("If the app being patched has never been opened, opens it for real first so macOS verifies it, waits for it to settle, and quits it. Without this a patched download is reported as damaged. The download record is then cleared so macOS runs the app from where it is.")
            bullet("Leaves a receipt inside the app. That is how it appears in the Patched list, where the gear sets a frame rate cap, the Metal Performance HUD, and Metal 4.")
            bullet("Each toolkit you add is stored in ~/Library/Application Support/GPTKPatcher so you can switch between versions later.")
            Text("A patched CrossOver is not supported by CodeWeavers.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
        .padding(16)
        .frame(width: 380)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•").foregroundStyle(.secondary)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct LogSheet: View {
    let lines: [String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Details").font(.headline)
            ScrollView {
                Text(lines.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 240)
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

/// Makes the window draggable by its background and keeps it at its content size.
private struct WindowConfigurator: NSViewRepresentable {
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
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Environment-variable hooks for screenshots and testing. They do nothing unless set.
///   GPTKPATCHER_CROSSOVER=<path>  GPTKPATCHER_DMG=<path>  GPTKPATCHER_OUTPUT=<folder>
///   GPTKPATCHER_PASTE=1  GPTKPATCHER_AUTOPATCH=1  GPTKPATCHER_OPEN_SETTINGS=1  GPTKPATCHER_SKIP_NOTICE=1
///   GPTKPATCHER_APPEARANCE=light|dark
enum DebugHooks {
    @MainActor
    static func apply(to engine: PatchEngine) {
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
    }
}

/// Shown on every launch. It can only be dismissed with Continue or Quit.
private struct SupportNoticeSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 10) {
                Text("Before You Begin")
                    .font(.title3.weight(.semibold))
                Text("Replacing the Game Porting Toolkit that CrossOver ships with is not supported by CodeWeavers. A patched CrossOver, whether it is a copy or your installed app, falls outside their support terms.")
                    .font(.body)
                Text("If you run into a problem, reproduce it with an unmodified CrossOver before contacting CodeWeavers support.")
                    .font(.body)
                HStack {
                    Spacer()
                    Button("Quit") { NSApp.terminate(nil) }
                    Button("Continue") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
                .padding(.top, 10)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 24)
        .padding(.bottom, 20)
        .padding(.horizontal, 24)
        .frame(width: 480)
        .interactiveDismissDisabled()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Before you begin")
    }
}

private struct PatchedAppRow: View {
    let app: PatchedApp
    var autoOpenSettings = false
    let onForget: () -> Void
    @State private var showSettings = false

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                .resizable()
                .interpolation(.high)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.url.deletingPathExtension().lastPathComponent)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("GPTK \(app.gptkVersion) · \(app.folderDescription)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([app.url]) }
                .controlSize(.small)
            Button { showSettings.toggle() } label: {
                Image(systemName: "gearshape")
            }
            .controlSize(.small)
            .help("Options: frame rate cap and Metal HUD")
            .accessibilityLabel("Options for \(app.name)")
            .popover(isPresented: $showSettings, arrowEdge: .bottom) { PatchedAppSettings(app: app) }
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .task {
            if autoOpenSettings { try? await Task.sleep(for: .milliseconds(600)); showSettings = true }
        }
        .contextMenu {
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([app.url]) }
            Button("Options…") { showSettings = true }
            Divider()
            Button("Remove from List") { onForget() }
        }
    }
}

/// Answers the Edit ▸ Paste command (⌘V) for the window when no text field has focus, so files
/// copied in Finder can be pasted straight into the patcher.
private struct PasteCatcher: NSViewRepresentable {
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

/// The result a patch will produce, shown before it runs so the outcome is never implied to exist.
private struct PlannedOutputRow: View {
    let name: String
    let sourceIcon: URL?

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: sourceIcon?.path ?? "/Applications"))
                .resizable()
                .interpolation(.high)
                .frame(width: 32, height: 32)
                .opacity(0.5)
            VStack(alignment: .leading, spacing: 2) {
                Text(name.hasSuffix(".app") ? String(name.dropLast(4)) : name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Will be created when you patch")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Output: \(name), will be created when you patch")
    }
}
