import SwiftUI

struct WhatChangesPopover: View {
    let mode: PatchMode
    var forNotProton = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What patching does").font(.headline)
            if forNotProton {
                notProton
            } else {
                crossOver
            }
            Text("A patched CrossOver is not supported by CodeWeavers.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 380)
    }

    @ViewBuilder private var notProton: some View {
        bullet("Patches the CrossOver that NotProton copies from, in place, and signs it for local use. Quit CrossOver first.")
        bullet("Swaps in the toolkit's D3DMetal, keeping the original as apple_gptk.stock.")
        bullet("Swaps in a DXMT or MoltenVK build when you choose one, keeping each original beside it. MoltenVK games get the launch options they need, restarting Steam with your OK if it is open.")
        bullet("Adds the nvngx.dll DLSS games look for. Turn DLSS on per game in NotProton's panel in Steam.")
        bullet("Copies those files into NotProton's copy of CrossOver, leaving the changes NotProton made there alone.")
        bullet("D3DMetal Frame Rate Cap adds the cap to a game's Steam launch options. Steam restarts to save it.")
        bullet("If a patch breaks games, use Remove Everything in NotProton, then set it up again.")
        bullet("D3DMetal runs on NotProton's Rosetta tool. Its FEX tool turns it off.")
    }

    @ViewBuilder private var crossOver: some View {
        if mode == .copy {
            bullet("Duplicates CrossOver.app. On APFS the copy takes almost no extra space.")
        } else {
            bullet("Patches the selected CrossOver.app in place. Quit CrossOver first.")
        }
        bullet("Swaps in the toolkit's D3DMetal, keeping the original as apple_gptk.stock.")
        bullet("Adds the nvngx.dll DLSS games look for, and routes DLSS to MetalFX in every bottle it launches.")
        bullet("Signs the patched app for local use, so macOS will open it.")
        bullet("Swaps in a MoltenVK build when you choose one, keeping the original as libMoltenVK.dylib.stock, and turns on the settings its games need.")
        bullet("Swaps in a DXMT build when you choose one, keeping the original as dxmt.stock.")
        bullet("Keeps every toolkit and build you add, to switch between later.")
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•").foregroundStyle(.secondary)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct LogSheet: View {
    let lines: [String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Details").font(.headline)
            ScrollView {
                Text(lines.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 240)
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

/// Acknowledged once; the same support information remains available in What changes.
struct SupportNoticeSheet: View {
    let onContinue: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 10) {
                Text("Before You Begin")
                    .font(.title3.weight(.semibold))
                Text("CodeWeavers does not support a patched CrossOver.")
                Text("Patching can break games. Don't report those problems to CodeWeavers or the NotProton developers.")
                Text("To reset NotProton, use Remove Everything in the NotProton app, then set it up again.")
                HStack {
                    Spacer()
                    Button("Quit") { NSApp.terminate(nil) }
                    Button("Continue") { onContinue(); dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
                .padding(.top, 14)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 28)
        .padding(.bottom, 24)
        .padding(.horizontal, 28)
        .frame(width: 480)
        .interactiveDismissDisabled()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Before you begin")
    }
}
