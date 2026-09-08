import Foundation

/// The usable part of a Game Porting Toolkit disk image: the `lib` folder holding
/// `external/D3DMetal.framework` and `wine/x86_64-windows`, plus its version.
struct GPTKPayload: Sendable {
    let lib: URL
    let version: String
    let minimumOS: String?
    /// Top level of the image the payload came from; Apple's licence and read-me sit there.
    let documentsRoot: URL?
    let mounts: [DiskImage]

    func detachAll(log: (String) -> Void) {
        for mount in mounts.reversed() { mount.detach(log: log) }
    }
}

enum GPTKSource {
    /// Mounts the image (and, if needed, the "Evaluation environment" image nested inside the
    /// full toolkit download) and locates the redistributable `lib` folder.
    static func locate(dmg: URL, log: (String) -> Void) throws -> GPTKPayload {
        var mounts: [DiskImage] = []
        var queue: [URL] = [dmg]
        var seen = 0
        do {
            while !queue.isEmpty && seen < 4 {
                let image = queue.removeFirst()
                seen += 1
                let mount = try DiskImage.attach(image, log: log)
                mounts.append(mount)
                if let lib = findLib(under: mount.mountPoint) {
                    let (version, minOS) = D3DMetalInfo.read(inLib: lib)
                    let resolved = version ?? versionFromFilename(dmg.lastPathComponent) ?? "unknown"
                    log("Found GPTK payload at \(lib.path) (D3DMetal \(resolved))")
                    return GPTKPayload(lib: lib, version: resolved, minimumOS: minOS,
                                       documentsRoot: mount.mountPoint, mounts: mounts)
                }
                let nested = findFiles(withExtension: "dmg", under: mount.mountPoint, maxDepth: 2)
                if !nested.isEmpty {
                    log("No payload at the top level; found nested image(s): \(nested.map(\.lastPathComponent).joined(separator: ", "))")
                    queue.append(contentsOf: nested)
                }
            }
        } catch {
            for mount in mounts.reversed() { mount.detach(log: log) }
            throw error
        }
        let top = (try? FileManager.default.contentsOfDirectory(atPath: mounts.first?.mountPoint.path ?? "")) ?? []
        for mount in mounts.reversed() { mount.detach(log: log) }
        throw PatchError.notGPTK("no folder containing external/D3DMetal.framework and wine/x86_64-windows was found. Top level contains: \(top.joined(separator: ", "))")
    }

    static func isValidLib(_ lib: URL) -> Bool {
        let fm = FileManager.default
        return fm.isDirectory(lib.appendingPathComponent("external/D3DMetal.framework"))
            && fm.isDirectory(lib.appendingPathComponent("wine/x86_64-windows"))
    }

    private static func findLib(under root: URL) -> URL? {
        let fm = FileManager.default
        let direct = root.appendingPathComponent("redist/lib")
        if isValidLib(direct) { return direct }
        let rootDepth = root.pathComponents.count
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        for case let url as URL in enumerator {
            if url.pathComponents.count - rootDepth > 6 { enumerator.skipDescendants(); continue }
            if url.lastPathComponent == "D3DMetal.framework" {
                let lib = url.deletingLastPathComponent().deletingLastPathComponent()
                if isValidLib(lib) { return lib }
            }
        }
        return nil
    }

    private static func findFiles(withExtension ext: String, under root: URL, maxDepth: Int) -> [URL] {
        let fm = FileManager.default
        let rootDepth = root.pathComponents.count
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil,
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var found: [URL] = []
        for case let url as URL in enumerator {
            if url.pathComponents.count - rootDepth > maxDepth { enumerator.skipDescendants(); continue }
            if url.pathExtension.lowercased() == ext { found.append(url) }
        }
        return found.sorted { $0.path < $1.path }
    }

    private static func versionFromFilename(_ name: String) -> String? {
        guard let range = name.range(of: #"\d+\.\d+"#, options: .regularExpression) else { return nil }
        return String(name[range])
    }
}

enum D3DMetalInfo {
    /// Reads the D3DMetal framework version (and its minimum macOS) from a GPTK `lib` folder.
    static func read(inLib lib: URL) -> (version: String?, minimumOS: String?) {
        let resources = lib.appendingPathComponent("external/D3DMetal.framework/Versions/A/Resources")
        for name in ["Info.plist", "version.plist"] {
            let plist = resources.appendingPathComponent(name)
            guard let dict = NSDictionary(contentsOf: plist) as? [String: Any] else { continue }
            let version = (dict["CFBundleShortVersionString"] as? String) ?? (dict["CFBundleVersion"] as? String)
            if let version, !version.isEmpty {
                return (version, dict["LSMinimumSystemVersion"] as? String)
            }
        }
        return (nil, nil)
    }
}
