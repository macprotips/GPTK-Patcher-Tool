import Foundation

struct CrossOverBundle: Sendable {
    let url: URL
    let identifier: String
    let name: String
    let version: String
    let build: String
    /// CodeWeavers' pre-release builds ("CrossOver Preview") ship ARM64 Wine next to x86_64.
    let isPreview: Bool
    let hasARM64Wine: Bool

    init(url: URL) throws {
        let fm = FileManager.default
        // Work on the real bundle: through an alias or symlink, a "copy" would be a link to the original.
        let url = url.resolvingSymlinksInPath()
        guard fm.fileExists(atPath: url.path) else {
            throw PatchError.io("“\(url.lastPathComponent)” could not be found. It may have been moved, renamed or deleted.")
        }
        guard url.pathExtension == "app", fm.isDirectory(url) else {
            throw PatchError.notCrossOver("expected an .app bundle")
        }
        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: infoURL) as? [String: Any] else {
            throw PatchError.notCrossOver("no readable Contents/Info.plist")
        }
        let identifier = (info["CFBundleIdentifier"] as? String) ?? ""
        guard identifier.lowercased().contains("codeweavers") else {
            throw PatchError.notCrossOver("bundle identifier is \(identifier.isEmpty ? "missing" : identifier)")
        }
        guard fm.isDirectory(url.appendingPathComponent("Contents/SharedSupport/CrossOver")) else {
            throw PatchError.notCrossOver("Contents/SharedSupport/CrossOver is missing")
        }
        self.url = url
        self.identifier = identifier
        let name = (info["CFBundleName"] as? String) ?? url.deletingPathExtension().lastPathComponent
        self.name = name
        self.version = (info["CFBundleShortVersionString"] as? String) ?? "?"
        self.build = (info["CFBundleVersion"] as? String) ?? "?"
        self.isPreview = name.localizedCaseInsensitiveContains("preview")
        let shared = url.appendingPathComponent("Contents/SharedSupport/CrossOver")
        self.hasARM64Wine = fm.isDirectory(shared.appendingPathComponent("lib/wine/aarch64-unix"))
    }

    /// True for a download macOS has not verified yet: it carries a quarantine record without the
    /// user-approved flag. Opening it once (and clicking Open) records the approval.
    var needsFirstLaunch: Bool {
        guard let marker = Quarantine.marker(of: url),
              let flags = UInt32(marker.split(separator: ";").first ?? "", radix: 16) else { return false }
        return flags & 0x0040 == 0
    }

    /// "CrossOver 26.3" or, for preview builds whose short version is a date, "CrossOver Preview 27.0.0.40921".
    var displayVersion: String {
        isPreview ? "\(name) \(build)" : "\(name) \(version)"
    }

    var sharedSupport: URL { url.appendingPathComponent("Contents/SharedSupport/CrossOver") }

    /// App-wide config. Its `[EnvironmentVariables]` are applied to every bottle this app launches.
    var globalConfig: URL { sharedSupport.appendingPathComponent("etc/CrossOver.conf") }

    /// CrossOver 25/26 keep GPTK in `lib64/apple_gptk`; CrossOver Preview 27 uses `lib/apple_gptk`.
    func gptkDirectory() throws -> URL {
        let fm = FileManager.default
        for parent in ["lib64", "lib"] {
            let candidate = sharedSupport.appendingPathComponent(parent).appendingPathComponent("apple_gptk")
            if fm.isDirectory(candidate) { return candidate }
        }
        throw PatchError.unsupportedLayout("neither lib64/apple_gptk nor lib/apple_gptk exists in \(sharedSupport.path). This CrossOver build has no D3DMetal support to replace.")
    }

    var installedD3DMetalVersion: String? {
        guard let dir = try? gptkDirectory() else { return nil }
        return D3DMetalInfo.read(inLib: dir).version
    }
}
