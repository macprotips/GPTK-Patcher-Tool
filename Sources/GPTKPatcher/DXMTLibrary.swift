import Foundation

/// A DXMT build stored in the app's library.
struct DXMTBuild: Identifiable, Hashable, Sendable {
    let version: String
    let path: URL
    let importedAt: Date
    let sourceName: String?

    var id: String { version }
    var displayName: String { "DXMT \(version)" }
}

/// Keeps imported DXMT builds in ~/Library/Application Support/GPTKPatcher/DXMT/<version>/.
/// A release archive holds one folder named after the tag (`v0.80/`) with the same
/// `x86_64-windows`, `i386-windows` and `x86_64-unix` directories CrossOver keeps in `lib/dxmt`.
enum DXMTLibrary {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/GPTKPatcher/DXMT", isDirectory: true)
    }

    private struct Manifest: Codable {
        var version: String
        var importedAt: Date
        var sourceName: String?
    }

    static let manifestName = "dxmt.json"

    /// Release archives are gzipped tarballs; accept the plain tar too.
    static func looksLikeArchive(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") || name.hasSuffix(".tar")
    }

    /// A usable build has at least the 64-bit Windows DLLs CrossOver loads.
    static func isValid(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent("x86_64-windows/d3d11.dll").path)
    }

    static func list(directory: URL = Self.directory) -> [DXMTBuild] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        let builds: [DXMTBuild] = names.compactMap { name in
            guard !name.hasPrefix(".") else { return nil }   // an import that never finished
            let path = directory.appendingPathComponent(name, isDirectory: true)
            guard isValid(path) else { return nil }
            let manifest = readManifest(in: path)
            let attrs = try? fm.attributesOfItem(atPath: path.path)
            return DXMTBuild(
                version: manifest?.version ?? name,
                path: path,
                importedAt: manifest?.importedAt ?? (attrs?[.creationDate] as? Date) ?? .distantPast,
                sourceName: manifest?.sourceName)
        }
        return builds.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }

    /// Unpacks a release archive into the library and returns the stored build.
    /// A version already in the library is returned as-is.
    static func importArchive(_ archive: URL, directory: URL = Self.directory, token: CancellationToken? = nil,
                              log: (String) -> Void) throws -> DXMTBuild {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let unpack = directory.appendingPathComponent(".unpacking", isDirectory: true)
        if fm.fileExists(atPath: unpack.path) { try fm.removeItem(at: unpack) }
        try fm.createDirectory(at: unpack, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: unpack) }

        log("Unpacking \(archive.lastPathComponent)…")
        try Shell.check("/usr/bin/tar", ["-xzf", archive.path, "-C", unpack.path], token: token)

        // The payload is either the single folder the archive wraps everything in, or the
        // archive root when a build was repacked without one.
        let entries = (try? fm.contentsOfDirectory(atPath: unpack.path))?.filter { !$0.hasPrefix(".") } ?? []
        var payload = unpack
        var version = versionFromName(archive.lastPathComponent)
        if entries.count == 1, fm.isDirectory(unpack.appendingPathComponent(entries[0])) {
            payload = unpack.appendingPathComponent(entries[0], isDirectory: true)
            version = versionFromName(entries[0]) ?? version
        }
        guard isValid(payload) else {
            throw PatchError.io("That archive doesn't contain a DXMT build. Expected a folder with x86_64-windows/d3d11.dll inside, like the dxmt-vX.XX-builtin.tar.gz from the DXMT releases page.")
        }
        guard let version else {
            throw PatchError.io("Could not tell which DXMT version that archive is. Keep the release's original name, such as dxmt-v0.80-builtin.tar.gz.")
        }

        let target = directory.appendingPathComponent(version, isDirectory: true)
        if isValid(target) {
            log("DXMT \(version) is already in the library.")
            return list(directory: directory).first { $0.version == version }
                ?? DXMTBuild(version: version, path: target, importedAt: Date(), sourceName: archive.lastPathComponent)
        }

        try Shell.check("/bin/chmod", ["-R", "u+w", payload.path], token: token)
        try Quarantine.strip(under: payload, token: token)
        let manifest = Manifest(version: version, importedAt: Date(), sourceName: archive.lastPathComponent)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: payload.appendingPathComponent(manifestName))

        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.moveItem(at: payload, to: target)
        log("Added DXMT \(version) to the library at \(target.path)")
        return DXMTBuild(version: version, path: target, importedAt: Date(), sourceName: archive.lastPathComponent)
    }

    static func remove(_ build: DXMTBuild) throws {
        guard build.path.path.hasPrefix(directory.path) else { return }
        try FileManager.default.removeItem(at: build.path)
    }

    /// "dxmt-v0.80-builtin.tar.gz" and "v0.80" both give "0.80".
    private static func versionFromName(_ name: String) -> String? {
        guard let range = name.range(of: #"\d+\.\d+(\.\d+)?"#, options: .regularExpression) else { return nil }
        return String(name[range])
    }

    private static func readManifest(in folder: URL) -> Manifest? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(manifestName)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Manifest.self, from: data)
    }
}
