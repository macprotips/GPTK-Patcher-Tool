import SwiftUI

/// Opens the frame rate cap. It only changes a game's launch options, so it is offered before
/// a patch and after one alike.
struct FrameCapButton: View {
    @Bindable var engine: PatchEngine
    @State private var shown = false

    var body: some View {
        Button("Frame Rate Cap…") { shown.toggle() }
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
            VStack(alignment: .leading, spacing: 2) {
                Text("D3DMetal Frame Rate Cap").font(.headline)
                Text("Added to a game's launch options in Steam.").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.bottom, 16)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Game")
                    Spacer()
                    Picker("Game", selection: $gameID) {
                        Text("Choose a game").tag("")
                        Divider()
                        ForEach(engine.steamGames) { Text($0.name).tag($0.id) }
                    }
                    .frame(width: 230)
                }
                HStack {
                    Text("Frame rate")
                    Spacer()
                    Picker("Frame rate", selection: $fps) {
                        Text("No cap").tag(0)
                        Divider()
                        ForEach(FrameCap.choices(including: current), id: \.self) { Text("\($0) fps").tag($0) }
                    }
                    .frame(width: 230)
                }
            }
            .labelsHidden()

            Text(note)
                .font(.caption)
                .foregroundStyle(engine.launchOptionsError == nil && engine.frameCapSupported
                                 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)

            HStack {
                Spacer()
                if engine.launchOptionsBusy { ProgressView().controlSize(.small) }
                Button("Apply") {
                    if Steam.running.isEmpty { apply() } else { confirmRestart = true }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(game == nil || fps == current || engine.launchOptionsBusy || !engine.frameCapSupported)
            }
            .padding(.top, 16)
        }
        .padding(16)
        .frame(width: 340)
        .onAppear(perform: engine.refreshSteam)
        .onChange(of: gameID) { fps = current > 0 ? current : 60 }
        .steamRestartConfirmation(isPresented: $confirmRestart, button: "Restart Steam and Apply", action: apply)
    }

    private var note: String {
        if !engine.frameCapSupported {
            return engine.notProtonHasCopy
                ? "NotProton's D3DMetal is too old for this cap. Patch with Game Porting Toolkit 4.0 or later."
                : "This CrossOver's D3DMetal is too old for this cap. Patch with Game Porting Toolkit 4.0 or later."
        }
        return engine.launchOptionsError ?? engine.launchOptionsMessage
            ?? "For DXMT games, use NotProton's panel in Steam."
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
    @State private var copied = false
    @State private var confirmRestart = false

    private var games: [Steam.Game] { engine.forNotProton ? engine.steamGames(for: build) : [] }

    var body: some View {
        if engine.forNotProton {
            if !games.isEmpty {
                let names = games.map(\.name).formatted(.list(type: .and))
                if engine.moltenVKIsSetUp(for: build) {
                    card("checkmark.circle.fill", .green, "\(names) \(games.count == 1 ? "is" : "are") set up in Steam. Added to the launch options:") {
                        added
                    }
                } else {
                    card("exclamationmark.circle.fill", .orange, "\(names) \(games.count == 1 ? "needs" : "need") launch options in Steam to use this build.") {
                        HStack(spacing: 8) {
                            Button("Set Up in Steam") {
                                if Steam.running.isEmpty { engine.setUpMoltenVK(for: build) } else { confirmRestart = true }
                            }
                            .controlSize(.small)
                            .disabled(engine.launchOptionsBusy)
                            .steamRestartConfirmation(isPresented: $confirmRestart, button: "Restart Steam and Set Up") {
                                engine.setUpMoltenVK(for: build)
                            }
                            if let result = engine.launchOptionsError ?? engine.launchOptionsMessage, !result.isEmpty {
                                Text(result).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        } else if let setup = build.setup {
            card("exclamationmark.circle.fill", .orange, setup) {
                if let option = build.launchOption {
                    HStack(spacing: 8) {
                        code(option)
                        Button(copied ? "Copied" : "Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(option, forType: .string)
                            copied = true
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    /// What Set Up in Steam wrote: the settings every game got, then each game's own argument.
    private var added: some View {
        VStack(alignment: .leading, spacing: 6) {
            code(LaunchOptions.moltenVKVariables.map { "\($0.name)=\($0.value)" }.joined(separator: "\n"))
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(text).fixedSize(horizontal: false, vertical: true)
            }
            controls().padding(.leading, 24)
        }
        .font(.subheadline)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(InputTileChrome(targeted: false, isEmpty: false, isError: false, cornerRadius: 10))
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
