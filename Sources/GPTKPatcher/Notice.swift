import SwiftUI

/// A message that needs attention: a tinted box with an icon, the text, an optional button at
/// the end and optional content underneath. How serious it is reads from its colour alone.
/// Explanations of a control are plain text beside it, not one of these.
struct Notice<Action: View, Extra: View>: View {
    enum Kind {
        case info, warning, success

        var tint: Color {
            switch self {
            case .info: return .secondary
            case .warning: return .orange
            case .success: return .green
            }
        }

        var symbol: String {
            switch self {
            case .info: return "info.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .success: return "checkmark.circle.fill"
            }
        }
    }

    let kind: Kind
    let text: String
    var symbol: String?
    @ViewBuilder let action: () -> Action
    @ViewBuilder let extra: () -> Extra

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: symbol ?? kind.symbol)
                    .foregroundStyle(kind.tint)
                    .frame(width: 16)
                Text(text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                action().controlSize(.small)
            }
            extra().padding(.leading, 26)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(kind.tint.opacity(kind == .info ? 0.08 : 0.10), in: shape)
        .overlay(shape.strokeBorder(kind.tint.opacity(kind == .info ? 0.14 : 0.22), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 10, style: .continuous) }
}

extension Notice where Action == EmptyView, Extra == EmptyView {
    init(_ kind: Kind, _ text: String, symbol: String? = nil) {
        self.init(kind: kind, text: text, symbol: symbol, action: { EmptyView() }, extra: { EmptyView() })
    }
}

extension Notice where Extra == EmptyView {
    init(_ kind: Kind, _ text: String, symbol: String? = nil, @ViewBuilder action: @escaping () -> Action) {
        self.init(kind: kind, text: text, symbol: symbol, action: action, extra: { EmptyView() })
    }
}

/// The bar along the bottom of a screen: a line across the window, then the buttons.
struct Footer<Content: View>: View {
    /// The window's side margin, which the line reaches past to touch both edges.
    let margin: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            Divider().padding(.horizontal, -margin)
            HStack(spacing: 10) { content() }
                .padding(.top, 20)
        }
        .padding(.top, 32)
    }
}
