import SwiftUI
import UniformTypeIdentifiers

/// The question asked on first launch: patch CrossOver for its own bottles, or the CrossOver
/// NotProton copies from. NotProton is greyed out until it is found on the Mac or located.
struct ChoiceView: View {
    @Bindable var engine: PatchEngine

    var body: some View {
        VStack(spacing: 26) {
            VStack(spacing: 6) {
                Text("GPTK Patcher Tool")
                    .font(.title2.weight(.semibold))
                Text("What are you patching?")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                ForEach(Destination.allCases) { place in
                    tile(place)
                }
            }
            .frame(maxWidth: 620)

            if let error = engine.notProtonLocateError {
                Text(error).font(.callout).foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    /// One square per choice. Both lay out the same rows at the same heights, so the icons,
    /// names and lines sit level whether or not a square carries the Locate button.
    @ViewBuilder private func tile(_ place: Destination) -> some View {
        let available = place == .crossOver || engine.notProtonInstalled
        if available {
            Button { engine.destination = place } label: { rows(place, available: true) }
                .buttonStyle(ChoiceTileStyle())
                .accessibilityElement(children: .combine)
        } else {
            // Not a button: the only thing to press in it is Locate.
            rows(place, available: false)
                .modifier(InputTileChrome(targeted: false, isEmpty: false, isError: false, cornerRadius: 12))
        }
    }

    private func rows(_ place: Destination, available: Bool) -> some View {
            VStack(spacing: 0) {
                Image(systemName: place.symbol)
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(available ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .frame(height: 48)
                    .padding(.bottom, 14)
                Text(place.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(available ? .primary : .secondary)
                    .padding(.bottom, 4)
                Text(available ? place.subtitle : "Not found on this Mac")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                // The same slot in both squares: empty, or the way to point at NotProton.
                // Clear, so the slot holds its height when there is no button to put in it.
                Color.clear
                    .frame(height: 24)
                    .overlay {
                        if !available {
                            Button("Locate NotProton…", action: locate)
                                .controlSize(.small)
                                .help("Choose NotProton.app if this app did not find it")
                        }
                    }
                    .padding(.top, 14)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 210)
            .contentShape(Rectangle())
    }

    private func locate() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "Choose NotProton.app"
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        engine.locateNotProton(url)
    }
}

/// The square behind a choice that can be made: the window's tile chrome, brighter under the
/// pointer.
private struct ChoiceTileStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(InputTileChrome(targeted: hovering || configuration.isPressed,
                                      isEmpty: false, isError: false, cornerRadius: 12))
            .onHover { hovering = $0 }
    }
}
