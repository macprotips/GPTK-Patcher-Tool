import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var engine = PatchEngine.shared
    var loadsData = true
    @State private var contentHeight: CGFloat = 0
    @State private var showLog = false
    @State private var showWhatChanges = false
    @State private var showSupportNotice = false
    @State private var windowTargeted = false
    @AppStorage("acknowledgedSupportNotice2") private var acknowledgedSupportNotice = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let width: CGFloat = 920
    private let margin: CGFloat = 36

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if engine.destination == nil {
                ChoiceView(engine: engine)
            } else {
                header
                    .padding(.bottom, 36)
                if isChoosing { options }
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
        }
        .padding(.horizontal, margin)
        // The title bar's strip is already above this, so the header starts just under the
        // window buttons. The launch question is centred in the window and keeps its own.
        .padding(.top, engine.destination == nil ? 34 : 26)
        // A screen with a footer ends on its buttons, which sit closer to the edge.
        .padding(.bottom, engine.destination == nil ? 32 : 24)
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)
        // Anywhere in the window works, not only the tile a file belongs to. A tile under the
        // pointer takes the drop first, so dropping on one still reads as landing there.
        .dropDestination(for: URL.self) { urls, _ in
            var accepted = false
            for url in urls where engine.route(url) { accepted = true }
            return accepted
        } isTargeted: { windowTargeted = $0 }
        .overlay {
            if windowTargeted && !engine.isBusy {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(4)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .background(GeometryReader { proxy in
            Color.clear.onChange(of: proxy.size.height, initial: true) { _, height in contentHeight = height }
        })
        // Only in the real window: previews and tests draw the view without one.
        .background {
            if loadsData {
                WindowConfigurator(contentHeight: contentHeight, width: width)
                PasteCatcher { engine.pasteFromPasteboard() }
            }
        }
        // Coming back from System Settings or NotProton is when things may have changed.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if loadsData { engine.windowBecameActive() }
        }
        .sheet(isPresented: $showLog) { LogSheet(lines: engine.logLines) }
        .sheet(isPresented: $showSupportNotice) { SupportNoticeSheet { acknowledgedSupportNotice = true } }
        .onAppear {
            guard loadsData else { return }
            NSApp.activate(ignoringOtherApps: true)
            engine.refreshToolkits()
            engine.refreshDXMT()
            engine.refreshMoltenVK()
            engine.refreshNotProton()
            engine.selectNotProtonsCrossOver()
            engine.refreshPatchedApps()
            DebugHooks.apply(to: engine)
        }

        .task {
            guard loadsData else { return }
            // Presented after the window is on screen; a sheet requested earlier can be dropped.
            try? await Task.sleep(for: .milliseconds(250))
            if !acknowledgedSupportNotice { showSupportNotice = true }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let back = backAction {
                BackButton(action: back)
                    .disabled(engine.isBusy)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("GPTK Patcher Tool")
                    .font(.title2.weight(.semibold))
                // The subtitle tells you what the screen in front of you will do. Once a patch is
                // running or finished it is describing something you are no longer choosing.
                if isChoosing {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 16)
        }
        .accessibilityElement(children: .contain)
    }

    /// Where the back arrow goes: from the form to the question, and from a result to the form.
    /// None while a patch runs, which has its own Cancel.
    private var backAction: (() -> Void)? {
        switch engine.phase {
        case .idle, .cancelled: return { engine.destination = nil }
        case .done, .failed: return engine.reset
        case .running: return nil
        }
    }

    private var subtitle: String {
        if engine.forNotProton {
            return engine.crossOver != nil
                ? "NotProton's CrossOver is already selected. Choose what to update."
                : "Update the Game Porting Toolkit, DXMT and MoltenVK in the CrossOver NotProton uses."
        }
        return engine.mode == .copy
            ? "Update the Game Porting Toolkit, DXMT and MoltenVK in a copy of CrossOver."
            : "Update the Game Porting Toolkit, DXMT and MoltenVK in your CrossOver."
    }

    /// The form is on screen: idle, or back from a cancelled patch.
    private var isChoosing: Bool {
        switch engine.phase {
        case .idle, .cancelled: return true
        default: return false
        }
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
        .disabled(engine.isBusy)
        // No .help here: a segmented picker shows one tooltip for the whole control, which would
        // describe the wrong segment half the time. The subtitle above states the current mode.
    }

    /// Above the tiles on the CrossOver screen: duplicate or in place, with what in place costs
    /// and whether to rename right beside it. NotProton is always in place, so it has none.
    @ViewBuilder private var options: some View {
        if !engine.forNotProton {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 24) {
                    modePicker
                    if engine.mode == .inPlace {
                        Toggle("Rename to show what it carries", isOn: $engine.renamePatchedApp)
                            .toggleStyle(.checkbox)
                            .font(.callout)
                            .disabled(engine.isBusy)
                            .help("Renames the app after what it carries, for example CrossOver (GPTK 4.0b3). Leave it off to keep the current name, which Dock icons and shortcuts point to.")
                    }
                }
                if engine.mode == .inPlace {
                    Label {
                        Text(engine.crossOverIsAlreadyPatched
                             ? "Already patched by this app. Patching again updates it."
                             : "A CrossOver update removes the patch.")
                    } icon: {
                        Image(systemName: engine.crossOverIsAlreadyPatched ? "info.circle" : "exclamationmark.triangle")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, 40)
        }
    }

    /// Problems that stand in the way of a patch, under the tiles in one stack, most pressing
    /// first. Explanations sit beside the control they explain instead.
    private var importingWhat: String {
        engine.importingDXMT != nil ? "DXMT" : engine.importingMoltenVK != nil ? "MoltenVK" : "the toolkit"
    }

    private var hasNotices: Bool {
        return engine.needsAppManagement || (engine.forNotProton && (engine.notProtonIsBehind || engine.notProtonUpdating))
            || engine.crossOverInstructions != nil || engine.isImporting || engine.downgradeNotice != nil
            || engine.compatibilityIssue != nil
    }

    @ViewBuilder private var notices: some View {
        let stack = VStack(spacing: 8) {
            if engine.needsAppManagement {
                Notice(.warning, "Turn on GPTK Patcher Tool under App Management before patching, so it can change \(engine.crossOverURL?.deletingPathExtension().lastPathComponent ?? "CrossOver").",
                       symbol: "lock.fill") {
                    Button("Open Privacy Settings", action: PatchEngine.openAppManagementSettings)
                }
            }
            if engine.forNotProton, engine.notProtonUpdating {
                Notice(.info, "Updating NotProton's copy…", symbol: "arrow.triangle.2.circlepath")
            } else if engine.forNotProton, engine.notProtonIsBehind {
                Notice(.warning, engine.notProtonUpdateError ?? "This CrossOver is patched, but NotProton's copy is not yet.") {
                    Button("Update NotProton", action: engine.updateNotProton)
                }
            }
            if let instructions = engine.crossOverInstructions {
                Notice(.warning, instructions)
            }
            if engine.isImporting {
                Notice(.info, engine.isCancelling ? "Cancelling import…" : "Adding \(importingWhat) to the library…", symbol: "arrow.down.circle.fill") {
                    Button("Cancel Import", action: engine.cancel).disabled(engine.isCancelling)
                }
            } else if let notice = engine.downgradeNotice {
                Notice(.warning, notice, symbol: "arrow.down.circle.fill")
            } else if let issue = engine.compatibilityIssue {
                Notice(.warning, issue)
            }
        }
        if hasNotices { stack.padding(.top, 20) }
    }

    // MARK: Idle form

    private var form: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Equal widths: each tile takes the same room whatever it happens to be showing.
            HStack(alignment: .top, spacing: 16) {
                Group {
                    if engine.forNotProton {
                        NotProtonCrossOverTile(engine: engine)
                    } else {
                        FileTile(label: "CrossOver", prompt: "Drop CrossOver.app here",
                                 contentType: .applicationBundle, fileExtension: "app",
                                 url: engine.crossOverURL, status: engine.crossOverStatus,
                                 onPick: { engine.route($0) }, onClear: engine.clearCrossOver)
                    }
                }
                .frame(maxWidth: .infinity)
                ToolkitTile(engine: engine)
                    .frame(maxWidth: .infinity)
                DXMTTile(engine: engine)
                    .frame(maxWidth: .infinity)
                MoltenVKTile(engine: engine)
                    .frame(maxWidth: .infinity)
            }

            notices

            if engine.mode == .copy {
                destinationRow.padding(.top, 32)
            }

            if !engine.forNotProton, !engine.patchedApps.isEmpty {
                patchedList.padding(.top, 32)
            }

            actionBar
        }
    }

    /// True once the copy this patch will make has a real name.
    private var showsPlannedOutput: Bool {
        engine.mode == .copy && engine.crossOver != nil && engine.hasSomethingToInstall
    }

    private var patchedList: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Already Patched Versions")
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(engine.patchedApps.enumerated()), id: \.element.id) { index, app in
                        if index > 0 { Divider().padding(.leading, 14) }
                        PatchedAppRow(app: app, onForget: {
                            PatchedAppRegistry.forget(app.url)
                            engine.refreshPatchedApps()
                        })
                    }
                }
            }
            .frame(height: CGFloat(min(engine.patchedApps.count, 3)) * 54)
            .modifier(InputTileChrome(targeted: false, isEmpty: false, isError: false, cornerRadius: 10))
        }
    }

    /// Where the copy goes: the folder alone until the inputs are chosen, then the full path
    /// with the name it will get.
    private var destinationRow: some View {
        VStack(alignment: .leading, spacing: 10) {
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

    private var destinationText: String {
        let url = showsPlannedOutput ? engine.outputURL : engine.outputFolder
        return url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private var actionBar: some View {
        Footer(margin: margin) {
            whatChangesLink
            if case .cancelled = engine.phase {
                Text("Patch cancelled.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !engine.logLines.isEmpty { Button("Details…") { showLog = true } }
            if engine.forNotProton { FrameCapButton(engine: engine) }
            Button(engine.forNotProton ? "Patch NotProton" : "Patch CrossOver", action: engine.patch)
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
        .popover(isPresented: $showWhatChanges, arrowEdge: .top) { WhatChangesPopover(mode: engine.mode, forNotProton: engine.forNotProton) }
    }

    // MARK: Running

    private func progress(_ current: PatchStep) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(engine.isCancelling ? "Cancelling and restoring files…" : engine.forNotProton ? "Patching NotProton…" : "Patching CrossOver…")
                .font(.headline)
                .padding(.bottom, 20)
            let sequence = PatchStep.sequence(for: engine.mode)
            let position = sequence.firstIndex(of: current) ?? 0
            VStack(alignment: .leading, spacing: 12) {
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
            Footer(margin: margin) {
                Text(engine.logLines.last ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Details…") { showLog = true }
                Button("Cancel", action: engine.cancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(engine.isCancelling)
            }
        }
    }

    // MARK: Done

    private func success(_ url: URL) -> some View {
        let carried = PatchedAppRegistry.components(at: url)
        return VStack(alignment: .leading, spacing: 0) {
            ResultHeader(symbol: "checkmark.circle.fill", tint: .green,
                         title: engine.forNotProton ? "NotProton patched successfully" : "CrossOver patched successfully",
                         detail: successDetail(url))
                .padding(.bottom, 30)

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 38, height: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(url.deletingPathExtension().lastPathComponent)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(url.deletingLastPathComponent().path
                            .replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                ForEach(carried, id: \.name) { item in
                    Divider().padding(.leading, 14)
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.green)
                        Text(item.name)
                        Spacer(minLength: 12)
                        Text(item.detail)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .accessibilityElement(children: .combine)
                }
            }
            .modifier(InputTileChrome(targeted: false, isEmpty: false, isError: false, cornerRadius: 10))

            if let build = engine.selectedMoltenVK?.catalogue {
                SetupNote(engine: engine, build: build).padding(.top, 20)
            }

            Footer(margin: margin) {
                Button("Details…") { showLog = true }
                Spacer()
                if engine.forNotProton { FrameCapButton(engine: engine) }
                if engine.notProtonUpdating {
                    ProgressView().controlSize(.small)
                } else if engine.notProtonIsBehind {
                    Button("Try Again", action: engine.updateNotProton)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                } else if engine.forNotProton {
                    if let steam = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Steam.bundleIdentifier) {
                        Button("Open Steam") { NSWorkspace.shared.open(steam) }
                            .keyboardShortcut(.defaultAction)
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
                Button("Done", action: engine.reset)
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private func successDetail(_ url: URL) -> String {
        guard engine.forNotProton else {
            return engine.mode == .copy
                ? "Open it like any other app. Your original CrossOver was not changed."
                : "The originals are kept inside the app, ending in .stock."
        }
        if engine.notProtonUpdating { return "Updating NotProton's copy…" }
        if engine.notProtonIsBehind {
            return engine.notProtonUpdateError ?? "NotProton's copy has not been updated yet."
        }
        return "NotProton's copy is updated. Games use it from their next launch."
    }

    // MARK: Failed

    private func failed(_ failure: Failure) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ResultHeader(symbol: "exclamationmark.triangle.fill", tint: .orange, title: failure.title, detail: nil)
                .padding(.bottom, 16)
            ScrollView {
                Text(failure.message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 150)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 44)
            Footer(margin: margin) {
                Button("Details…") { showLog = true }
                Spacer()
                if failure.needsPermission {
                    Button("Open Privacy Settings", action: PatchEngine.openAppManagementSettings)
                }
                if failure.leftovers.isEmpty {
                    Button("Try Again", action: engine.reset)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Try Again", action: engine.reset)
                    Button("Quit Them and Patch") { engine.quitLeftovers(failure.leftovers) }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
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

/// The back arrow at the top left of a screen.
private struct BackButton: View {
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(hovering && isEnabled ? .primary : .secondary)
                .frame(width: 26, height: 26)
                .background(Color.primary.opacity(hovering && isEnabled ? 0.08 : 0),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .keyboardShortcut("[", modifiers: .command)
        .help("Back")
        .accessibilityLabel("Back")
    }
}

/// The outcome at the top of the result screens: a large icon, then what happened beside it.
private struct ResultHeader: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String?

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 30))
                .foregroundStyle(tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title3.weight(.semibold))
                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
