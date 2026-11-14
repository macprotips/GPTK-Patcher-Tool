import SwiftUI
import UniformTypeIdentifiers

/// The Game Porting Toolkit input. Empty: a drop target for the .dmg. With toolkits in the
/// library: the same surface showing the chosen version, which is a menu of every imported
/// version plus Add and Remove. Dropping another image on it adds that version.
struct ToolkitTile: View {
    @Bindable var engine: PatchEngine

    @State private var targeted = false
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let dateFormat: Date.FormatStyle = .dateTime.month(.abbreviated).day().year()

    var body: some View {
        if showsLibrary {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Game Porting Toolkit", detail: engine.installedD3DMetal, strong: true)
                libraryTile
            }
        } else {
            FileTile(label: "Game Porting Toolkit", labelDetail: engine.installedD3DMetal, prompt: "Drop the toolkit .dmg here",
                     contentType: .diskImage, fileExtension: "dmg",
                     url: engine.importingImage,
                     status: engine.toolkitStatus,
                     onPick: { engine.route($0) }, onClear: engine.dismissToolkitError)
        }
    }

    private var showsLibrary: Bool {
        if engine.importingImage != nil { return false }
        if case .failed = engine.toolkitStatus { return false }
        return !engine.toolkits.isEmpty
    }

    private var libraryTile: some View {
        // The whole tile is the menu, so a click anywhere on it opens the list.
        Menu {
            Picker("Toolkit version", selection: selection) {
                Text("Unchanged").tag(Toolkit?.none)
                ForEach(engine.toolkits) { toolkit in
                    Text(toolkit.displayName).tag(Optional(toolkit))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Button("Add Toolkit…", action: openPanel)
            if let toolkit = engine.selectedToolkit {
                Button("Remove \(toolkit.displayName) from Library", role: .destructive) { engine.removeToolkit(toolkit) }
            }
        } label: {
            HStack(alignment: .center, spacing: 12) {
                TileGlyph(symbol: "gamecontroller.fill", highlighted: targeted)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(engine.selectedToolkit?.displayName ?? "Unchanged")
                            .font(.body.weight(.medium))
                            .foregroundStyle(engine.selectedToolkit == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    if let toolkit = engine.selectedToolkit {
                        let caption = targeted ? "Release to add this image to the library" : detail(for: toolkit)
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(targeted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .help(caption)
                    } else {
                        Text("This CrossOver keeps its own toolkit")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 14)
            .padding(.trailing, 14)
            .frame(maxWidth: .infinity)
            .frame(height: FileTile.height)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("Choose a toolkit version, add another, or remove one")
        .accessibilityLabel("Toolkit version")
        .accessibilityValue(engine.selectedToolkit?.displayName ?? "none")
        .modifier(InputTileChrome(targeted: targeted, hovering: hovering, isEmpty: false, isError: false))
        .overlay(alignment: .topTrailing) {
            if engine.selectedToolkit != nil {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 14))
                    .padding(10)
                    .accessibilityHidden(true)
            }
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Add Toolkit…", action: openPanel)
            if let toolkit = engine.selectedToolkit {
                Button("Remove \(toolkit.displayName) from Library", role: .destructive) { engine.removeToolkit(toolkit) }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            var accepted = false
            for url in urls where engine.route(url) { accepted = true }
            return accepted
        } isTargeted: { targeted = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: targeted)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Game Porting Toolkit")
    }

    private var selection: Binding<Toolkit?> {
        Binding(get: { engine.selectedToolkit }, set: { if let t = $0 { engine.selectToolkit(t) } else { engine.clearToolkit() } })
    }

    private func detail(for toolkit: Toolkit) -> String {
        var lines = ["D3DMetal \(D3DMetalInfo.read(inLib: toolkit.lib).version ?? toolkit.version)"]
        if let minimum = toolkit.minimumOS { lines.append("macOS \(minimum)+") }
        if toolkit.importedAt > .distantPast { lines.append("Added \(toolkit.importedAt.formatted(Self.dateFormat))") }
        return lines.joined(separator: "\n")
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.diskImage]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a Game Porting Toolkit disk image to add"
        if panel.runModal() == .OK, let url = panel.url { engine.importToolkit(from: url) }
    }
}
