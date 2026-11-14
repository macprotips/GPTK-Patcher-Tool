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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if engine.destination == nil {
                ChoiceView(engine: engine)
            } else {
                header
                    .padding(.bottom, isChoosing ? 30 : 34)
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
        .padding(.horizontal, 36)
        .padding(.top, 34)
        .padding(.bottom, 32)
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
        .background(WindowConfigurator(contentHeight: contentHeight, width: width))
        .background(PasteCatcher { engine.pasteFromPasteboard() })
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
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
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
            // Where the games run, not what to do about it. Switching is rare, so it sits out of
            // the way as a menu rather than taking a row of the window.
            if isChoosing, let place = engine.destination {
                // Back to the question, where what can and cannot be chosen is spelled out.
                Button("\(place.title) · Change") { engine.destination = nil }
                    .buttonStyle(.link)
                    .font(.callout)
                    .disabled(engine.isBusy)
                    .help("Change what you are patching")
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var subtitle: String {
        switch engine.destination {
        case .none: return "A newer Game Porting Toolkit, DXMT and MoltenVK."
        case .notProton: return engine.notProtonHasCopy
            ? "NotProton's CrossOver is already selected. Choose what to update."
            : "Update the toolkit in the CrossOver NotProton uses."
        case .crossOver: return engine.mode == .copy
            ? "Update the Game Porting Toolkit in a copy of CrossOver."
            : "Update the Game Porting Toolkit in your CrossOver."
        }
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

    /// What sits above the tiles: the NotProton status line, or the mode and what it costs.
    @ViewBuilder private var options: some View {
        if engine.forNotProton {
            notProtonStatus
        } else {
            modePicker.padding(.bottom, engine.mode == .inPlace ? 14 : 30)
            if engine.mode == .inPlace {
                inPlaceWarning.padding(.bottom, 12)
                Toggle("Rename the app to show its toolkit version", isOn: $engine.renamePatchedApp)
                    .toggleStyle(.checkbox)
                    .font(.callout)
                    .disabled(engine.isBusy)
                    .help("Off keeps the app's current name and path, which is what aliases, the Dock and existing bottle sessions point at")
                    .padding(.bottom, 26)
            }
        }
    }

    /// A line for NotProton only when there is something to do or to know. The usual case,
    /// the CrossOver it already uses, needs none.
    @ViewBuilder private var notProtonStatus: some View {
        if let rival = engine.notProtonRival {
            statusLine("exclamationmark.triangle.fill", .orange,
                       "NotProton will use \(rival.deletingPathExtension().lastPathComponent) instead. It lists one CrossOver per build, and that one comes first.") {
                Button("Patch That One") { engine.setCrossOver(rival) }.controlSize(.small)
            }
        } else if engine.crossOver == nil {
            statusLine("info.circle.fill", .secondary,
                       "Add the CrossOver that NotProton uses, or the one you plan to give it.") { EmptyView() }
        } else if engine.notProtonIsBehind, !engine.notProtonUpdating, let error = engine.notProtonUpdateError {
            // Only when bringing NotProton's copy level did not work, with the reason.
            statusLine("exclamationmark.triangle.fill", .orange, error) {
                Button("Try Again", action: engine.updateNotProton).controlSize(.small)
            }
        } else if !engine.notProtonHasCopy {
            statusLine("checkmark.circle.fill", .green,
                       "After patching, set this CrossOver up in NotProton.") { EmptyView() }
        }
    }

    private func statusLine<Trailing: View>(_ symbol: String, _ tint: Color, _ text: String,
                                            @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            trailing()
        }
        .font(.callout)
        .padding(.bottom, 28)
        .accessibilityElement(children: .combine)
    }

    /// What in-place patching costs. A copy this app already patched gets a note instead.
    @ViewBuilder
    private var inPlaceWarning: some View {
        if engine.crossOverIsAlreadyPatched {
            Label {
                Text("Already patched by this app. Patching again updates it.")
            } icon: {
                Image(systemName: "info.circle.fill").foregroundStyle(.secondary)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } else {
            Label {
                Text("A CrossOver update removes the patch, and macOS will ask for its permissions again.")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Idle form

    private var form: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Equal widths: each tile takes the same room whatever it happens to be showing.
            HStack(alignment: .top, spacing: 16) {
                FileTile(label: engine.forNotProton ? "NotProton's CrossOver" : "CrossOver", prompt: "Drop CrossOver.app here",
                         contentType: .applicationBundle, fileExtension: "app",
                         url: engine.crossOverURL, status: engine.crossOverStatus,
                         onPick: { engine.route($0) }, onClear: engine.clearCrossOver)
                    .frame(maxWidth: .infinity)
                ToolkitTile(engine: engine)
                    .frame(maxWidth: .infinity)
                DXMTTile(engine: engine)
                    .frame(maxWidth: .infinity)
                MoltenVKTile(engine: engine)
                    .frame(maxWidth: .infinity)
            }

            if let instructions = engine.crossOverInstructions {
                Label {
                    Text(instructions)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
            }

            if engine.isImporting {
                HStack {
                    Text(engine.isCancelling ? "Cancelling import…" : "Importing toolkit…")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel Import", action: engine.cancel).disabled(engine.isCancelling)
                }
                .padding(.top, 10)
            } else if let notice = engine.downgradeNotice {
                Label(notice, systemImage: "arrow.down.circle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            } else if let issue = engine.compatibilityIssue {
                Label(issue, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }

            if engine.mode == .copy {
                destinationRow.padding(.top, 32)
            }

            if !engine.forNotProton, !engine.patchedApps.isEmpty {
                patchedList.padding(.top, 30)
            }

            actionBar.padding(.top, 30)
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
        HStack(spacing: 12) {
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
                .padding(.bottom, 4)
            Text(current == .signing ? "Preparing the modified app for local use and checking its signature." : " ")
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
            HStack {
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
            .padding(.top, 24)
        }
    }

    // MARK: Done

    private func success(_ url: URL) -> some View {
        let carried = PatchedAppRegistry.components(at: url)
        return VStack(alignment: .leading, spacing: 0) {
            // Centred, because the result is one statement rather than another form to read
            // down the left edge.
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.green)
                Text(engine.forNotProton ? "NotProton patched successfully" : "CrossOver patched successfully")
                    .font(.title3.weight(.semibold))
                Text(successDetail(url))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 24)

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
                SetupNote(engine: engine, build: build).padding(.top, 14)
            }

            HStack {
                Button("Details…") { showLog = true }
                Spacer()
                if engine.forNotProton { FrameCapButton(engine: engine) }
                Button("Done", action: engine.reset)
                    .keyboardShortcut(.cancelAction)
                if engine.notProtonUpdating {
                    ProgressView().controlSize(.small)
                } else if engine.notProtonIsBehind {
                    Button("Try Again", action: engine.updateNotProton)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                } else if engine.forNotProton, !engine.notProtonHasCopy, let notProton = NotProton.appURL {
                    Button("Open NotProton") { NSWorkspace.shared.open(notProton) }
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
            }
            .padding(.top, 24)
        }
    }

    private func successDetail(_ url: URL) -> String {
        guard engine.forNotProton else {
            return engine.mode == .copy
                ? "Open it like any other app. Your original CrossOver was not changed."
                : "The stock toolkit was kept as apple_gptk.stock inside the app."
        }
        if engine.notProtonUpdating { return "Updating NotProton's copy…" }
        if engine.notProtonIsBehind {
            return engine.notProtonUpdateError ?? "NotProton's copy has not been updated yet."
        }
        return engine.notProtonHasCopy
            ? "NotProton's copy is updated. Games use it from their next launch."
            : "One step left. Open NotProton and set up \(url.deletingPathExtension().lastPathComponent)."
    }

    // MARK: Failed

    private func failed(_ failure: Failure) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.orange)
                Text(failure.title)
                    .font(.headline)
            }
            .padding(.bottom, 12)
            ScrollView {
                Text(failure.message)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 150)
            .fixedSize(horizontal: false, vertical: true)
            Text("Details includes the patch log and any recovery steps.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 10)
            HStack {
                Button("Details…") { showLog = true }
                Spacer()
                if failure.needsPermission {
                    Button("Open Privacy Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles")!)
                    }
                }
                Button("Try Again", action: engine.reset)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, 24)
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
