import SwiftUI

/// Opens the frame rate cap. It only changes a game's launch options, so it is offered before
/// a patch and after one alike.
struct FrameCapButton: View {
    @Bindable var engine: PatchEngine
    @State private var shown = false

    var body: some View {
        Button("D3DMetal Frame Rate Cap…") { shown.toggle() }
            .popover(isPresented: $shown, arrowEdge: .top) { FrameCapPopover(engine: engine) }
            .help("Cap a game's frame rate on D3DMetal")
    }
}

/// Caps one game's frame rate on D3DMetal through its Steam launch options. NotProton's panel
/// in Steam already has the cap for DXMT.
struct FrameCapPopover: View {
    @Bindable var engine: PatchEngine
    @State private var gameID = ""
    @State private var fps = 60
    @State private var confirmRestart = false

    private var game: Steam.Game? { engine.steamGames.first { $0.id == gameID } }
    private var current: Int { engine.frameCaps[gameID] ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("D3DMetal Frame Rate Cap")
                .font(.headline)
                .padding(.bottom, 14)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Game:").gridColumnAlignment(.trailing)
                    Picker("Game", selection: $gameID) {
                        Text("Choose a game").tag("")
                        Divider()
                        ForEach(engine.steamGames) { Text($0.name).tag($0.id) }
                    }
                }
                GridRow {
                    Text("Frame rate:")
                    HStack(spacing: 8) {
                        Picker("Frame rate", selection: $fps) {
                            Text("No cap").tag(0)
                            Divider()
                            ForEach(FrameCap.choices(including: current), id: \.self) { Text("\($0) fps").tag($0) }
                        }
                        .fixedSize()
                        Spacer(minLength: 8)
                        if engine.launchOptionsBusy { ProgressView().controlSize(.small) }
                        Button("Apply") {
                            if Steam.running.isEmpty { apply() } else { confirmRestart = true }
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(game == nil || fps == current || engine.launchOptionsBusy || !(engine.frameCapSupported || engine.frameCapAfterPatch))
                    }
                }
            }
            .labelsHidden()

            Text(note)
                .font(.caption)
                .foregroundStyle(engine.launchOptionsError == nil && (engine.frameCapSupported || engine.frameCapAfterPatch)
                                 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
        }
        .padding(18)
        .frame(width: 360)
        .onAppear(perform: engine.refreshSteam)
        .onChange(of: gameID) { fps = current > 0 ? current : 60 }
        .steamRestartConfirmation(isPresented: $confirmRestart, button: "Restart Steam and Apply", action: apply)
    }

    private var note: String {
        if !engine.frameCapSupported, engine.frameCapAfterPatch, let toolkit = engine.selectedToolkit {
            return engine.launchOptionsError ?? engine.launchOptionsMessage
                ?? "Takes effect once you patch NotProton with \(toolkit.displayName)."
        }
        if !engine.frameCapSupported {
            return "NotProton's D3DMetal is too old for this cap. Patch with Game Porting Toolkit 4.0 or later."
        }
        return engine.launchOptionsError ?? engine.launchOptionsMessage
            ?? "Saved to Steam launch options. DXMT uses NotProton's own cap."
    }

    private func apply() {
        if let game { engine.setFrameCap(fps, for: game) }
    }
}

/// The step a MoltenVK build leaves for its games. For CrossOver, the launch option to copy.
/// For NotProton, where Steam is the Mac's own, a button that sets the games up.
struct SetupNote: View {
    @Bindable var engine: PatchEngine
    let build: MoltenVKLibrary.KnownBuild
    /// The game whose Add for Me is waiting on the user's OK to restart Steam.
    @State private var restarting: Steam.Game?

    private var games: [Steam.Game] { engine.forNotProton ? engine.steamGames(for: build) : [] }

    var body: some View {
        if engine.forNotProton {
            if !games.isEmpty {
                if engine.moltenVKIsSetUp(for: build) {
                    let names = games.map(\.name).formatted(.list(type: .and))
                    card("checkmark.circle.fill", .green, "\(names) \(games.count == 1 ? "is" : "are") set up in Steam. Added to the launch options:") {
                        added
                    }
                } else {
                    let waiting = games.filter { !engine.moltenVKIsSetUp(game: $0, for: build) }
                    let names = waiting.map(\.name).formatted(.list(type: .and))
                    card("exclamationmark.circle.fill", .orange, "\(names) \(waiting.count == 1 ? "needs" : "need") these launch options in Steam. Copy them in yourself, or let the app add them, which restarts Steam if it is open.") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(waiting) { game in
                                needed(for: game)
                            }
                            if let error = engine.launchOptionsError {
                                Text(error).font(.caption).foregroundStyle(.orange)
                            } else if engine.launchOptionsBusy, let progress = engine.launchOptionsMessage {
                                Text(progress).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .steamRestartConfirmation(isPresented: Binding(get: { restarting != nil }, set: { if !$0 { restarting = nil } }),
                                              button: "Restart Steam and Add") {
                        if let game = restarting { engine.setUpMoltenVK(for: build, only: game) }
                    }
                }
            }
        } else if let setup = build.setup {
            card("exclamationmark.circle.fill", .orange, setup) {
                if let option = build.launchOption {
                    HStack(spacing: 8) {
                        code(option)
                        CopyButton(text: option)
                    }
                }
            }
        }
    }

    /// One game's launch options as they need to read in Steam, with a button to copy them.
    private func needed(for game: Steam.Game) -> some View {
        let argument = build.steamApps.first { $0.id == game.id }?.argument
        let options = LaunchOptions.settingUpMoltenVK(in: "", settings: build.settings, argument: argument)
        return VStack(alignment: .leading, spacing: 4) {
            Text(game.name).font(.caption.weight(.semibold))
            HStack(alignment: .top, spacing: 8) {
                code(options)
                CopyButton(text: options)
                Button("Add for Me") {
                    if Steam.running.isEmpty { engine.setUpMoltenVK(for: build, only: game) } else { restarting = game }
                }
                .controlSize(.small)
                .disabled(engine.launchOptionsBusy)
            }
        }
    }

    /// What the app wrote: the settings every game got, then each game's own argument.
    private var added: some View {
        VStack(alignment: .leading, spacing: 6) {
            code(LaunchOptions.moltenVKVariables(build.settings).map { "\($0.name)=\($0.value)" }.joined(separator: "\n"))
            ForEach(games) { game in
                if let argument = build.steamApps.first(where: { $0.id == game.id })?.argument {
                    HStack(spacing: 8) {
                        code(argument)
                        Text("\(game.name) only").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func code(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func card<Controls: View>(_ symbol: String, _ tint: Color, _ text: String,
                                      @ViewBuilder controls: () -> Controls) -> some View {
        // The icon, gap and margins of the rows in the result list above, so the two line up.
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(tint)
                Text(text).fixedSize(horizontal: false, vertical: true)
            }
            controls().padding(.leading, 22)
        }
        .font(.subheadline)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(InputTileChrome(targeted: false, isEmpty: false, isError: false, cornerRadius: 10))
    }
}

/// Copies its text, and says so until the text changes.
private struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button(copied ? "Copied" : "Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
        }
        .controlSize(.small)
        .onChange(of: text) { copied = false }
    }
}

private extension View {
    /// Asks before closing Steam, which is the only way a launch option change is kept.
    func steamRestartConfirmation(isPresented: Binding<Bool>, button: String, action: @escaping () -> Void) -> some View {
        confirmationDialog("Restart Steam to save this?", isPresented: isPresented) {
            Button(button, action: action)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Steam only keeps launch options changed while it is closed. Any game that is running will quit.")
        }
    }
}
