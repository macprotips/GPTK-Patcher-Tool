import SwiftUI

/// The CrossOver being patched for NotProton. Which one is NotProton's choice, so the tile only
/// shows it: a menu when NotProton has more than one, and where to go when it has none.
struct NotProtonCrossOverTile: View {
    @Bindable var engine: PatchEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("NotProton's CrossOver", strong: true)
            Group {
                if let app = engine.crossOverURL {
                    if engine.notProtonCrossOvers.count > 1 {
                        Menu {
                            ForEach(engine.notProtonCrossOvers, id: \.path) { other in
                                Button(other.deletingPathExtension().lastPathComponent) { engine.setCrossOver(other) }
                            }
                        } label: {
                            selected(app, chevron: true)
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                        .help("Choose which of NotProton's CrossOver versions to patch")
                    } else {
                        selected(app, chevron: false)
                    }
                } else {
                    missing
                }
            }
            .modifier(InputTileChrome(targeted: false, isEmpty: engine.crossOverURL == nil, isError: isError))
            .overlay(alignment: .topTrailing) {
                if case .ok = engine.crossOverStatus {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 14))
                        .padding(10)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private var isError: Bool {
        if case .failed = engine.crossOverStatus { return true } else { return false }
    }

    private func selected(_ app: URL, chevron: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                .resizable()
                .interpolation(.high)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    // Without ".app", and on two lines if need be: "CrossOver Preview" is too
                    // long for one at this width.
                    Text(app.deletingPathExtension().lastPathComponent)
                        .font(.body.weight(.medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if chevron {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                switch engine.crossOverStatus {
                case .ok(let text), .checking(let text):
                    caption(text, error: false)
                case .failed(let text):
                    caption(text, error: true)
                case .empty:
                    EmptyView()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .frame(height: FileTile.height)
        .contentShape(Rectangle())
    }

    private func caption(_ text: String, error: Bool) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(error ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .help(text)
    }

    private var missing: some View {
        VStack(spacing: 8) {
            Text("Set up a version of CrossOver in NotProton first")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let notProton = NotProton.appURL {
                Button("Open NotProton") { NSWorkspace.shared.open(notProton) }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .frame(height: FileTile.height)
    }
}
