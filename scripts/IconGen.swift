import SwiftUI
import AppKit

/// Draws the app icon: the letters GPTK over a download arrow, for "get the toolkit in".
/// Rendered on Apple's 1024pt icon grid, where the shape occupies the middle 824pt.
private struct IconView: View {
    private let canvas: CGFloat = 1024
    private let plate: CGFloat = 824
    private let stroke: CGFloat = 42

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: plate * 0.2247, style: .continuous)
                .fill(Color(red: 0.13, green: 0.13, blue: 0.145))
                .frame(width: plate, height: plate)

            VStack(spacing: 40) {
                Text("GPTK")
                    .font(.system(size: 236, weight: .bold, design: .rounded))
                    .kerning(-8)
                    .foregroundStyle(.white)
                arrow
            }
            .offset(y: -6)
        }
        .frame(width: canvas, height: canvas)
    }

    /// Shaft and head in one stroked path, with the line it lands on beneath.
    private var arrow: some View {
        VStack(spacing: 30) {
            Path { p in
                p.move(to: CGPoint(x: 105, y: 0))
                p.addLine(to: CGPoint(x: 105, y: 150))
                p.move(to: CGPoint(x: 20, y: 74))
                p.addLine(to: CGPoint(x: 105, y: 159))
                p.addLine(to: CGPoint(x: 190, y: 74))
            }
            .stroke(style: StrokeStyle(lineWidth: stroke, lineCap: .round, lineJoin: .round))
            .foregroundStyle(.white)
            .frame(width: 210, height: 180)

            Capsule()
                .fill(.white)
                .frame(width: 300, height: stroke)
        }
    }
}

@MainActor
private func writePNG(size: CGFloat, to url: URL) throws {
    let renderer = ImageRenderer(content: IconView())
    renderer.scale = size / 1024
    guard let cg = renderer.cgImage else { throw Failure("could not render \(Int(size))px") }
    let rep = NSBitmapImageRep(cgImage: cg)
    rep.size = NSSize(width: size, height: size)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw Failure("could not encode \(Int(size))px")
    }
    try data.write(to: url)
}

private struct Failure: LocalizedError {
    let text: String
    init(_ text: String) { self.text = text }
    var errorDescription: String? { text }
}

@main
@MainActor
struct IconGen {
    static func main() throws {
        let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        // The set macOS expects: each point size at 1x and 2x.
        for points in [16, 32, 128, 256, 512] {
            try writePNG(size: CGFloat(points), to: out.appendingPathComponent("icon_\(points)x\(points).png"))
            try writePNG(size: CGFloat(points * 2), to: out.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
        }
        print(out.path)
    }
}
