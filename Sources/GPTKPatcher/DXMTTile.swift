import SwiftUI
import UniformTypeIdentifiers

/// The DXMT input, beside CrossOver and the toolkit. Empty: a drop target for a release archive.
/// With builds in the library: the same surface showing the chosen version, which is a menu of
/// every imported version plus Add and Remove.
struct DXMTTile: View {
    @Bindable var engine: PatchEngine

    @State private var targeted = false
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let dateFormat: Date.FormatStyle = .dateTime.month(.abbreviated).day().year()

    var body: some View {
        if showsLibrary {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) { SectionLabel("DXMT"); BetaTag() }
                libraryTile
            }
        } else {
            FileTile(label: "DXMT", beta: true, prompt: "Drop a DXMT release here",
                     contentType: .archive, fileExtension: "tar.gz",
                     url: engine.importingDXMT,
                     status: engine.dxmtStatus,
                     onPick: { engine.route($0) }, onClear: engine.clearDXMT)
        }
    }

    private var showsLibrary: Bool {
        if engine.importingDXMT != nil { return false }
        if case .failed = engine.dxmtStatus { return false }
        return !engine.dxmtBuilds.isEmpty
    }

    private var libraryTile: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 26))
                .foregroundStyle(Color.accentColor.opacity(targeted ? 1 : 0.85))
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 3) {
                Menu {
                    // "Unchanged" is one of the choices rather than a separate command, so the menu
                    // is a single list of what this patch will do to DXMT.
                    Picker("DXMT version", selection: selection) {
                        Text("Unchanged").tag(DXMTBuild?.none)
                        ForEach(engine.dxmtBuilds) { build in
                            Text(build.displayName).tag(Optional(build))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    Divider()
                    Button("Add DXMT Release…", action: openPanel)
                    if let build = engine.selectedDXMT {
                        Button("Remove \(build.displayName) from Library", role: .destructive) { engine.removeDXMT(build) }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(engine.selectedDXMT?.displayName ?? "Not replacing DXMT")
                            .font(.body.weight(.medium))
                            .foregroundStyle(engine.selectedDXMT == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Choose a DXMT version, add another, or remove one")
                .accessibilityLabel("DXMT version")
                .accessibilityValue(engine.selectedDXMT?.displayName ?? "none")
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
        .modifier(InputTileChrome(targeted: targeted, hovering: hovering, isEmpty: false, isError: false))
        .overlay(alignment: .topTrailing) {
            if engine.selectedDXMT != nil {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 14))
                    .padding(10)
                    .accessibilityHidden(true)
            }
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Add DXMT Release…", action: openPanel)
            if let build = engine.selectedDXMT {
                Button("Remove \(build.displayName) from Library", role: .destructive) { engine.removeDXMT(build) }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            var accepted = false
            for url in urls where engine.route(url) { accepted = true }
            return accepted
        } isTargeted: { targeted = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: targeted)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("DXMT")
    }

    private var caption: String {
        if targeted { return "Release to add this build to the library" }
        guard let build = engine.selectedDXMT else { return "This CrossOver keeps its own DXMT" }
        var lines = ["Runs DirectX 11 games"]
        if build.importedAt > .distantPast { lines.append("Added \(build.importedAt.formatted(Self.dateFormat))") }
        return lines.joined(separator: "\n")
    }

    private var selection: Binding<DXMTBuild?> {
        Binding(get: { engine.selectedDXMT }, set: { if let b = $0 { engine.selectDXMT(b) } else { engine.clearDXMT() } })
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a DXMT release archive"
        if panel.runModal() == .OK, let url = panel.url {
            guard DXMTLibrary.looksLikeArchive(url) else {
                engine.dxmtStatus = .failed("Not a DXMT release archive (.tar.gz).")
                return
            }
            engine.importDXMT(from: url)
        }
    }
}
