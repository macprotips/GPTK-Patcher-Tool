import SwiftUI

struct PatchedAppRow: View {
    let app: PatchedApp
    let onForget: () -> Void
    @State private var showSettings = false
    @State private var repairing = false
    @State private var repairResult = ""
    @State private var showRepairResult = false

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                .resizable()
                .interpolation(.high)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.url.deletingPathExtension().lastPathComponent)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if app.patchReplaced {
                    Text("A CrossOver update removed the patch. Patch it again.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("GPTK \(app.gptkVersion) · \(app.folderDescription)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([app.url]) }
                .controlSize(.small)
            Button { showSettings.toggle() } label: {
                Image(systemName: "gearshape")
            }
            .controlSize(.small)
            .help("Options: frame rate cap, Metal HUD and Metal 4")
            .accessibilityLabel("Options for \(app.name)")
            .disabled(repairing)
            .popover(isPresented: $showSettings, arrowEdge: .bottom) { PatchedAppSettings(app: app) }
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        // The list gives each row 54 points, one of which is the divider.
        .frame(minHeight: 53)
        .contextMenu {
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([app.url]) }
            Button("Options…") { showSettings = true }
            Button(repairing ? "Repairing Launch…" : "Repair Launch", action: repairLaunch).disabled(repairing)
            Divider()
            Button("Remove from List") { onForget() }
        }
        .alert("Launch repair", isPresented: $showRepairResult) {
            Button("OK", role: .cancel) {}
        } message: { Text(repairResult) }
    }

    private func repairLaunch() {
        guard !repairing else { return }
        repairing = true
        let location = app.url
        Task {
            let result = await Task.detached { () -> Result<Void, Error> in
                Result { try AppSigning.repair(CrossOverBundle(url: location), log: { _ in }) }
            }.value
            repairing = false
            switch result {
            case .success: repairResult = "The patched app's local signature has been repaired and verified. Open it from this location."
            case .failure(let error): repairResult = error.localizedDescription
            }
            showRepairResult = true
        }
    }
}
