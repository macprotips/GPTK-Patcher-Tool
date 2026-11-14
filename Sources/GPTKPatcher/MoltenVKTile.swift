import SwiftUI
import UniformTypeIdentifiers

/// The MoltenVK input, the last tile in the row. MoltenVK is CrossOver's Vulkan driver, which
/// runs Doom, Wolfenstein and Detroit. The tile is a menu of the builds in the library, one of
/// which ships with the app, plus Add and Remove.
struct MoltenVKTile: View {
    @Bindable var engine: PatchEngine

    @State private var targeted = false
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if showsLibrary {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) { SectionLabel("MoltenVK", strong: true); BetaTag() }
                libraryTile
            }
        } else {
            FileTile(label: "MoltenVK", beta: true, prompt: "Drop a MoltenVK build here",
                     contentType: .data, fileExtension: "dylib",
                     url: engine.importingMoltenVK,
                     status: engine.moltenVKStatus,
                     onPick: { engine.route($0) }, onClear: engine.clearMoltenVK)
        }
    }

    private var showsLibrary: Bool {
        if engine.importingMoltenVK != nil { return false }
        if case .failed = engine.moltenVKStatus { return false }
        return !engine.moltenVKBuilds.isEmpty
    }

    private var libraryTile: some View {
        // The whole tile is the menu, so a click anywhere on it opens the list.
        Menu {
            Picker("MoltenVK build", selection: selection) {
                Text("Unchanged").tag(MoltenVKBuild?.none)
                ForEach(engine.moltenVKBuilds) { build in
                    Text(build.menuTitle).tag(Optional(build))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Button("Add MoltenVK Build…", action: openPanel)
            if let build = engine.selectedMoltenVK {
                Text(build.detail)
                if let setup = build.setupNote { Text(setup) }
                // A build that ships with the app is not the user's to remove.
                if !build.isBuiltIn {
                    Button("Remove \(build.displayName) from Library", role: .destructive) { engine.removeMoltenVK(build) }
                }
            }
        } label: {
            HStack(alignment: .center, spacing: 12) {
                TileGlyph(text: "VK", highlighted: targeted)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(engine.selectedMoltenVK?.displayName ?? "Unchanged")
                            .font(.body.weight(.medium))
                            .foregroundStyle(engine.selectedMoltenVK == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(targeted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(caption)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .frame(height: FileTile.height)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("Choose a MoltenVK build, add another, or remove one")
        .accessibilityLabel("MoltenVK build")
        .accessibilityValue(engine.selectedMoltenVK?.displayName ?? "none")
        .modifier(InputTileChrome(targeted: targeted, hovering: hovering, isEmpty: false, isError: false))
        .overlay(alignment: .topTrailing) {
            if engine.selectedMoltenVK != nil {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 14))
                    .padding(10)
                    .accessibilityHidden(true)
            }
        }
        .onHover { hovering = $0 }
        .dropDestination(for: URL.self) { urls, _ in
            var accepted = false
            for url in urls where engine.route(url) { accepted = true }
            return accepted
        } isTargeted: { targeted = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: targeted)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("MoltenVK")
    }

    private var caption: String {
        if targeted { return "Release to add this build to the library" }
        guard let build = engine.selectedMoltenVK else { return "This CrossOver keeps its own MoltenVK" }
        return [build.catalogue?.games.replacingOccurrences(of: " · ", with: "\n"),
                build.version.map { "MoltenVK \($0)" }].compactMap { $0 }.joined(separator: "\n")
    }

    private var selection: Binding<MoltenVKBuild?> {
        Binding(get: { engine.selectedMoltenVK },
                set: { if let build = $0 { engine.selectMoltenVK(build) } else { engine.clearMoltenVK() } })
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a MoltenVK build (libMoltenVK.dylib, or the archive it came in)"
        if panel.runModal() == .OK, let url = panel.url {
            guard MoltenVKLibrary.looksLikeBuild(url) else {
                engine.moltenVKStatus = .failed("Not a MoltenVK build (.dylib or archive).")
                return
            }
            engine.importMoltenVK(from: url)
        }
    }
}
