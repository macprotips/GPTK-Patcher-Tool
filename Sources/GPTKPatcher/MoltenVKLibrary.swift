import Foundation

/// A MoltenVK build stored in the app's library. CrossOver ships its own; replacing it is what
/// makes Vulkan games such as Doom, Wolfenstein and Detroit: Become Human run.
struct MoltenVKBuild: Identifiable, Hashable, Sendable {
    /// Taken from the file or archive the user supplied, because that is what tells builds apart:
    /// a Doom build and a Detroit build both report the same MoltenVK version.
    let name: String
    let version: String?
    let path: URL
    let architectures: [String]
    let importedAt: Date

    var id: String { name }
    var dylib: URL { path.appendingPathComponent(MoltenVKLibrary.dylibName) }
    var displayName: String { name }
    var detail: String {
        var parts: [String] = []
        if let version { parts.append("MoltenVK \(version)") }
        parts.append(architectures.joined(separator: " + "))
        return parts.joined(separator: " · ")
    }
}

/// Keeps imported builds in ~/Library/Application Support/GPTKPatcher/MoltenVK/<name>/.
enum MoltenVKLibrary {
    static let dylibName = "libMoltenVK.dylib"

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/GPTKPatcher/MoltenVK", isDirectory: true)
    }

    private struct Manifest: Codable {
        var name: String
        var version: String?
        var architectures: [String]
        var importedAt: Date
        var sourceName: String?
    }

    static let manifestName = "moltenvk.json"

    /// A `.dylib`, or an archive holding one.
    static func looksLikeBuild(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "dylib" || DXMTLibrary.looksLikeArchive(url) || url.pathExtension.lowercased() == "zip"
    }

    static func isValid(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(dylibName).path)
    }

    static func list(directory: URL = Self.directory) -> [MoltenVKBuild] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.compactMap { name -> MoltenVKBuild? in
            guard !name.hasPrefix(".") else { return nil }
            let path = directory.appendingPathComponent(name, isDirectory: true)
            guard isValid(path) else { return nil }
            let manifest = readManifest(in: path)
            let dylib = path.appendingPathComponent(dylibName)
            return MoltenVKBuild(
                name: manifest?.name ?? name,
                version: manifest?.version ?? version(of: dylib),
                path: path,
                architectures: manifest?.architectures ?? architectures(of: dylib),
                importedAt: manifest?.importedAt ?? .distantPast)
        }
        .sorted { $0.importedAt > $1.importedAt }
    }

    /// Copies the library out of a `.dylib` or archive and into the app's own store.
    static func importBuild(_ source: URL, directory: URL = Self.directory, token: CancellationToken? = nil,
                            log: (String) -> Void) throws -> MoltenVKBuild {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let unpack = directory.appendingPathComponent(".unpacking", isDirectory: true)
        if fm.fileExists(atPath: unpack.path) { try fm.removeItem(at: unpack) }
        try fm.createDirectory(at: unpack, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: unpack) }

        let dylib: URL
        if source.pathExtension.lowercased() == "dylib" {
            dylib = source
        } else {
            log("Unpacking \(source.lastPathComponent)…")
            if source.pathExtension.lowercased() == "zip" {
                try Shell.check("/usr/bin/unzip", ["-q", "-o", source.path, "-d", unpack.path], token: token)
            } else {
                try Shell.check("/usr/bin/tar", ["-xzf", source.path, "-C", unpack.path], token: token)
            }
            guard let found = firstDylib(under: unpack) else {
                throw PatchError.io("No \(dylibName) was found inside \(source.lastPathComponent). Pick the MoltenVK build's .dylib, or the archive that contains it.")
            }
            dylib = found
        }

        // A wrong or corrupt file here breaks Vulkan for every game, so check before storing it.
        let archs = architectures(of: dylib)
        guard !archs.isEmpty else {
            throw PatchError.io("\(dylib.lastPathComponent) is not a macOS library. Pick the libMoltenVK.dylib from a MoltenVK build.")
        }
        let name = buildName(from: source, dylib: dylib)
        guard FileSafety.isSafeComponent(name) else {
            throw PatchError.io("Rename the file or folder to something simpler; “\(name)” cannot be used as a name.")
        }

        let target = directory.appendingPathComponent(name, isDirectory: true)
        let staging = directory.appendingPathComponent(".importing", isDirectory: true)
        if fm.fileExists(atPath: staging.path) { try fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            try fm.copyItem(at: dylib, to: staging.appendingPathComponent(dylibName))
            try Shell.check("/bin/chmod", ["-R", "u+w", staging.path], token: token)
            try Quarantine.strip(under: staging, token: token)
            let manifest = Manifest(name: name, version: version(of: dylib), architectures: archs,
                                    importedAt: Date(), sourceName: source.lastPathComponent)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(manifest).write(to: staging.appendingPathComponent(manifestName))
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.moveItem(at: staging, to: target)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        log("Added MoltenVK build “\(name)” (\(archs.joined(separator: ", "))) to the library")
        return MoltenVKBuild(name: name, version: version(of: target.appendingPathComponent(dylibName)),
                             path: target, architectures: archs, importedAt: Date())
    }

    static func remove(_ build: MoltenVKBuild) throws {
        guard build.path.path.hasPrefix(directory.path) else { return }
        try FileManager.default.removeItem(at: build.path)
    }

    /// `lipo -info` without the tool: read the Mach-O header, handling fat binaries.
    static func architectures(of dylib: URL) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: dylib) else { return [] }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4096), head.count >= 8 else { return [] }
        func be32(_ offset: Int) -> UInt32 {
            head[head.startIndex + offset ..< head.startIndex + offset + 4]
                .reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        func le32(_ offset: Int) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { $0 | (UInt32(head[head.startIndex + offset + $1]) << (8 * UInt32($1))) }
        }
        func name(_ cpu: UInt32) -> String? {
            switch cpu & ~0x0100_0000 {   // mask the 64-bit ABI flag
            case 7: return "x86_64"
            case 12: return "arm64"
            default: return nil
            }
        }
        // Magic is read big-endian, so a little-endian Mach-O (everything on macOS today) shows up
        // byte-reversed: 0xcffaedfe rather than 0xfeedfacf.
        let magic = be32(0)
        switch magic {
        case 0xcafe_babe, 0xcafe_babf:                       // fat, always big-endian
            let count = Int(be32(4))
            guard count > 0, count < 32 else { return [] }
            let stride = magic == 0xcafe_babe ? 20 : 32
            return (0..<count).compactMap { i in
                let offset = 8 + i * stride
                return offset + 4 <= head.count ? name(be32(offset)) : nil
            }
        case 0xcffa_edfe, 0xcefa_edfe:                       // thin, little-endian
            return name(le32(4)).map { [$0] } ?? []
        case 0xfeed_facf, 0xfeed_face:                       // thin, big-endian
            return name(be32(4)).map { [$0] } ?? []
        default:
            return []
        }
    }

    /// MoltenVK reports its version as a bare "1.4.2" string inside the binary.
    static func version(of dylib: URL) -> String? {
        guard let result = try? Shell.run("/usr/bin/strings", ["-n", "5", dylib.path]), result.status == 0 else { return nil }
        return result.stdout.split(separator: "\n")
            .first { $0.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) != nil }
            .map(String.init)
    }

    private static func firstDylib(under root: URL) -> URL? {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles]) else { return nil }
        var fallback: URL?
        for case let url as URL in walker where url.pathExtension.lowercased() == "dylib" {
            if url.lastPathComponent == dylibName { return url }
            fallback = fallback ?? url
        }
        return fallback
    }

    /// "Detroit-MoltenVK-unofficial-0.03.zip" and ".../Detroit.../libMoltenVK.dylib" both give
    /// "Detroit-MoltenVK-unofficial-0.03"; a bare libMoltenVK.dylib falls back to its folder.
    private static func buildName(from source: URL, dylib: URL) -> String {
        var candidate = source.lastPathComponent
        for suffix in [".tar.gz", ".tgz", ".tar", ".zip", ".dylib"] where candidate.lowercased().hasSuffix(suffix) {
            candidate = String(candidate.dropLast(suffix.count))
            break
        }
        if candidate.lowercased() == "libmoltenvk" {
            let folder = source.deletingLastPathComponent().lastPathComponent
            candidate = folder.isEmpty ? "MoltenVK" : folder
        }
        _ = dylib
        return candidate.isEmpty ? "MoltenVK" : candidate
    }

    private static func readManifest(in folder: URL) -> Manifest? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(manifestName)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Manifest.self, from: data)
    }
}
