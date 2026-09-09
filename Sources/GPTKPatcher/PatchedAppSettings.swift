import SwiftUI

/// Options for one patched CrossOver, opened from the gear in the Patched list. Values are read
/// from and written to one config file: the app's own CrossOver.conf ("App defaults") or a
/// bottle's cxbottle.conf, which overrides the app-wide value for that bottle.
struct PatchedAppSettings: View {
    let app: PatchedApp

    private enum Scope: Hashable {
        case allBottles
        case bottle(BottleEnv.Bottle)

        var bottle: BottleEnv.Bottle? { if case .bottle(let b) = self { return b } else { return nil } }
    }

    @State private var scope: Scope = .allBottles
    @State private var bottles: [BottleEnv.Bottle] = []
    @State private var values = GraphicsOptions()
    @State private var saved = GraphicsOptions()
    @State private var error: String?
    @State private var applied = false
    @State private var running: BottleEnv.RunningBottle?
    /// A process scan is in progress; it runs off the main thread because it spawns ps and lsof.
    @State private var checking = false
    /// Bottles whose own config sets one of these keys, which beats the app-wide value for that bottle.
    @State private var overrides: [String] = []
    @State private var confirmQuit = false
    /// Shown when Apply is clicked while the bottle is running: programs keep the settings they
    /// launched with, so the bottle is quit first and the settings written after.
    @State private var promptQuitToApply = false
    @State private var applyAfterQuit = false
    @State private var resetAfterQuit = false
    @State private var quitting = false
    @State private var saving = false
    @State private var scanID = UUID()

    private var busy: Bool { checking || quitting || saving }

    private var isDirty: Bool {
        values.fpsEnabled != saved.fpsEnabled || values.hud != saved.hud || values.metal4 != saved.metal4
            || (values.fpsEnabled && values.fpsValue != saved.fpsValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.headline)
                Text("GPTK \(app.gptkVersion)").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.bottom, 16)

            // Target
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Apply to")
                    Spacer()
                    Picker("Apply to", selection: $scope) {
                        Text("App defaults").tag(Scope.allBottles)
                        if !bottles.isEmpty { Divider() }
                        ForEach(bottles) { bottle in
                            Text(bottle.name).tag(Scope.bottle(bottle))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 260)
                    .disabled(busy)
                }
                Text(scope == .allBottles
                     ? "Defaults for bottles launched with this copy. Per-bottle settings take priority."
                     : "Only this bottle, with any CrossOver. Unset values inherit this app's defaults.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if scope == .allBottles, !overrides.isEmpty {
                    Text("Overridden by " + overrides.prefix(3).joined(separator: "; ")
                         + (overrides.count > 3 ? "; and \(overrides.count - 3) more" : "")
                         + ". Choose a bottle to change or reset its overrides.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider().padding(.vertical, 16)

            // Settings
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Text("D3DMetal Frame Rate Cap")
                    Spacer()
                    if values.fpsEnabled {
                        TextField("", value: $values.fpsValue, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 48)
                            .accessibilityLabel("Frame rate limit")
                        Stepper("", value: $values.fpsValue, in: 1...1000).labelsHidden()
                        Text("fps").foregroundStyle(.secondary)
                    } else {
                        Text("Off").foregroundStyle(.secondary)
                    }
                    Toggle("", isOn: $values.fpsEnabled).toggleStyle(.switch).controlSize(.small).labelsHidden()
                        .accessibilityLabel("D3DMetal Frame Rate Cap")
                }
                .frame(height: 24)

                HStack(spacing: 8) {
                    Text("Metal Performance HUD")
                    Spacer()
                    Text(values.hud ? "On" : "Off").foregroundStyle(.secondary)
                    Toggle("", isOn: $values.hud).toggleStyle(.switch).controlSize(.small).labelsHidden()
                        .accessibilityLabel("Metal Performance HUD")
                }
                .frame(height: 24)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Metal 4")
                        Spacer()
                        Picker("Metal 4", selection: $values.metal4) {
                            ForEach(Metal4Mode.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 190)
                    }
                    .frame(height: 24)
                    Text(scope.bottle == nil ? Metal4Mode.defaultDescription : "Default inherits this CrossOver's Metal 4 setting. On and Off override it for this bottle.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(busy)

            if let running {
                runningNotice(running)
                    .padding(.top, 16)
            }

            // Footer
            if let error {
                ScrollView {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 90)
                .padding(.top, 16)
            }
            HStack(spacing: 10) {
                if error == nil, applied, !isDirty {
                    Label("Applied", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                Spacer()
                if scope.bottle != nil {
                    Button("Use App Defaults") { apply(reset: true) }
                        .disabled(busy)
                }
                Button("Apply") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isDirty || busy || (values.fpsEnabled && !(1...1000).contains(values.fpsValue)))
            }
            .padding(.top, 20)
        }
        .padding(20)
        .frame(width: 400)
        .onAppear {
            bottles = BottleEnv.listBottles()
            load()
        }
        .onChange(of: scope) { _, _ in load() }
        .confirmationDialog(quitTitle, isPresented: $confirmQuit, titleVisibility: .visible) {
            Button("Quit", role: .destructive, action: quitBottle)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Any game or program running in it will close, and unsaved progress may be lost.")
        }
        .alert(applyQuitTitle, isPresented: $promptQuitToApply) {
            Button("Quit Bottle and Apply", role: .destructive) {
                applyAfterQuit = true
                quitBottle()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Programs already running keep the settings they launched with, so the bottle has to quit before these changes can take effect. Unsaved progress in any game may be lost.")
        }
    }

    // MARK: Running bottle

    private func runningNotice(_ running: BottleEnv.RunningBottle) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(runningTitle(running))
                    .font(.callout.weight(.medium))
                Text(running.isStale
                     ? "It was started by a CrossOver that has since been moved or renamed, so programs hang waiting on it. Quit it."
                     : "Programs still running keep the settings they launched with. Quit the bottle for changes to take effect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(quitting ? "Quitting…" : "Quit Bottle") { confirmQuit = true }
                .controlSize(.small)
                .disabled(busy)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.orange.opacity(0.10)))
    }

    private func runningTitle(_ running: BottleEnv.RunningBottle) -> String {
        let subject = scope.bottle == nil ? "A bottle" : "This bottle"
        if running.isStale { return "\(subject)'s session is stale" }
        if running.serverPID == nil { return "\(subject) still has \(running.clientPIDs.count) program\(running.clientPIDs.count == 1 ? "" : "s") running" }
        return "\(subject) is still running"
    }

    private var quitTitle: String {
        if let bottle = scope.bottle { return "Quit everything running in the “\(bottle.name)” bottle?" }
        return "Quit the running bottle?"
    }

    private var applyQuitTitle: String {
        if let name = scope.bottle?.name ?? running?.prefix.lastPathComponent { return "The “\(name)” bottle is still running" }
        return "A bottle is still running"
    }

    private func refreshOverrides() {
        overrides = bottles.compactMap { bottle in
            var parts: [String] = []
            if let cap = CXConfig.value(of: "D3DM_MAX_FPS", in: bottle.conf) { parts.append("cap \(cap) fps") }
            if let hud = CXConfig.value(of: "MTL_HUD_ENABLED", in: bottle.conf) { parts.append("HUD \(hud == "1" ? "on" : "off")") }
            if let m4 = CXConfig.value(of: "D3DM_MTL4", in: bottle.conf) { parts.append("Metal 4 \(Metal4Mode.from(stored: m4).title.lowercased())") }
            return parts.isEmpty ? nil : "\(bottle.name) (\(parts.joined(separator: ", ")))"
        }
    }

    private nonisolated static func scan(_ bottle: BottleEnv.Bottle?, app: URL) -> BottleEnv.RunningBottle? {
        if let bottle { return BottleEnv.runningBottle(for: bottle) }
        return BottleEnv.runningBottles(startedFrom: app).first
    }

    private func refreshRunning(then completion: @escaping @MainActor () -> Void = {}) {
        let bottle = scope.bottle
        let location = app.url
        let id = UUID()
        scanID = id
        checking = true
        Task {
            let result = await Task.detached { Self.scan(bottle, app: location) }.value
            guard scanID == id else { return }
            running = result
            checking = false
            completion()
        }
    }

    /// Ends the running session(s) in scope, then re-checks; a pending Apply is written only if nothing is left.
    private func quitBottle() {
        guard running != nil else { return }
        let bottle = scope.bottle
        let location = app.url
        quitting = true
        Task {
            let left = await Task.detached { () -> BottleEnv.RunningBottle? in
                let targets = bottle.map { [BottleEnv.runningBottle(for: $0)].compactMap { $0 } }
                    ?? BottleEnv.runningBottles(startedFrom: location)
                for target in targets { try? BottleEnv.quit(target) }
                return Self.scan(bottle, app: location)
            }.value
            quitting = false
            running = left
            let pending = applyAfterQuit
            applyAfterQuit = false
            if left != nil {
                error = "Some programs in the bottle couldn't be quit."
            } else {
                error = nil
                if pending { write(reset: resetAfterQuit) }
            }
        }
    }

    // MARK: Config

    private var conf: URL { scope.bottle?.conf ?? app.globalConfig }

    private func load() {
        let v = GraphicsOptions.load(from: conf, inheriting: scope.bottle == nil ? nil : app.globalConfig)
        values = v
        saved = v
        error = nil
        applied = false
        refreshRunning()
        refreshOverrides()
    }

    private func apply(reset: Bool = false) {
        resetAfterQuit = reset
        refreshRunning {
            if running != nil { promptQuitToApply = true } else { write(reset: reset) }
        }
    }

    private func write(reset: Bool = false) {
        guard !saving, !quitting else { return }
        let changes = reset ? AppSettings.keys.map { ($0, nil as String?) } : values.changes(from: saved)
        let location = app.url
        let bottleConf = scope.bottle?.conf
        saving = true
        error = nil
        Task {
            let outcome = await Task.detached { () -> Result<Void, Error> in
                Result { try AppSettings.apply(changes, to: CrossOverBundle(url: location), bottleConfig: bottleConf) }
            }.value
            saving = false
            switch outcome {
            case .success:
                load()
                applied = true
            case .failure(let failure):
                error = "Couldn't save: \(failure.localizedDescription)"
            }
        }
    }
}
