import SwiftUI
import UniformTypeIdentifiers

/// One input surface. Empty: a dashed drop target. Selected: the same surface showing the file's
/// icon, name and validation line. Drag-over, hover, error and checking states are all on this view.
struct FileTile: View {
    let label: String
    let prompt: String
    let contentType: UTType
    let fileExtension: String
    let url: URL?
    let status: DropStatus
    let onPick: (URL) -> Void
    let onClear: () -> Void

    @State private var targeted = false
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let height: CGFloat = 112

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(label)
            tile
        }
    }

    private var tile: some View {
        Button(action: openPanel) {
            Group {
                if url == nil { emptyContent } else { selectedContent }
            }
            .frame(maxWidth: .infinity)
            .frame(height: Self.height)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .modifier(InputTileChrome(targeted: targeted, hovering: hovering, isEmpty: url == nil, isError: isError))
        .overlay(alignment: .topTrailing) { badge.padding(10) }
        .onHover { hovering = $0 }
        .dropDestination(for: URL.self) { urls, _ in
            let accepted = urls.filter { ["app", "dmg"].contains($0.pathExtension.lowercased()) }
            for url in accepted { onPick(url) }
            return !accepted.isEmpty
        } isTargeted: { targeted = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: targeted)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(url == nil ? "Opens a file chooser. You can also drop a file here." : "Choose a different file.")
        .accessibilityAddTraits(.isButton)
    }

    private var emptyContent: some View {
        VStack(spacing: 6) {
            Image(systemName: targeted ? "arrow.down.circle.fill" : (contentType == .diskImage ? "externaldrive" : "app.dashed"))
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(targeted ? Color.accentColor : Color.secondary)
                .frame(height: 30)
            Text(targeted ? "Release to add" : prompt)
                .font(.callout)
                .foregroundStyle(targeted ? Color.accentColor : Color.secondary)
                .lineLimit(1)
            if !targeted {
                Text("or click to choose")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
    }

    private var selectedContent: some View {
        HStack(alignment: .center, spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 3) {
                Text(url?.lastPathComponent ?? "")
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail.text)
                        .font(.caption)
                        .foregroundStyle(detail.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 14)
        .padding(.trailing, 14)
    }

    private var detail: (text: String, isError: Bool)? {
        switch status {
        case .empty: return nil
        case .checking(let text): return (text, false)
        case .ok(let text): return (text, false)
        case .failed(let text): return (text, true)
        }
    }

    @ViewBuilder
    private var icon: some View {
        if let url, FileManager.default.fileExists(atPath: url.path) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .interpolation(.high)
                .frame(width: 40, height: 40)
                .opacity(isError ? 0.6 : 1)
        }
    }

    @ViewBuilder
    private var badge: some View {
        switch status {
        case .empty:
            EmptyView()
        case .checking:
            ProgressView().controlSize(.small)
        case .ok, .failed:
            if hovering || isError {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .help("Remove")
                .accessibilityLabel("Remove \(url?.lastPathComponent ?? label)")
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 14))
                    .accessibilityHidden(true)
            }
        }
    }

    private var isError: Bool { if case .failed = status { return true } else { return false } }

    private var accessibilityValue: String {
        switch status {
        case .empty: return "No file selected"
        case .checking: return "\(url?.lastPathComponent ?? ""), checking"
        case .ok(let text): return "\(url?.lastPathComponent ?? ""), \(text)"
        case .failed(let text): return "\(url?.lastPathComponent ?? ""), not accepted. \(text)"
        }
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle, .diskImage]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.message = "Choose \(label)"
        if contentType == .applicationBundle { panel.directoryURL = URL(fileURLWithPath: "/Applications") }
        if panel.runModal() == .OK, let url = panel.url { onPick(url) }
    }
}

/// Section label used above every group in the window.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }
}

/// Shared look of an input tile or list container: quiet fill, hairline border, dashed while empty,
/// a touch lighter on hover, accent while a drag hovers.
struct InputTileChrome: ViewModifier {
    let targeted: Bool
    var hovering = false
    let isEmpty: Bool
    let isError: Bool
    var cornerRadius: CGFloat = 10

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(fill))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: targeted ? 2 : 1, dash: isEmpty && !targeted ? [4, 3] : []))
                    .foregroundStyle(borderColor)
            )
    }

    private var fill: AnyShapeStyle {
        if targeted { return AnyShapeStyle(Color.accentColor.opacity(0.14)) }
        if isEmpty { return AnyShapeStyle(.quaternary.opacity(hovering ? 0.62 : 0.5)) }
        // A faint lift on hover. Anything stronger competes with the checkmark for "selected".
        return AnyShapeStyle(Color(nsColor: .controlBackgroundColor).opacity(hovering ? 0.75 : 1))
    }

    private var borderColor: Color {
        if targeted { return .accentColor }
        if isError { return .red.opacity(0.6) }
        return Color(nsColor: .separatorColor)
    }
}
