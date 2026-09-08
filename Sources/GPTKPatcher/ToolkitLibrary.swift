import Foundation

/// A Game Porting Toolkit payload stored in the app's library.
struct Toolkit: Identifiable, Hashable, Sendable {
    let version: String
    let lib: URL
    let importedAt: Date
    let minimumOS: String?
    let sourceName: String?

    var id: String { version }
    var displayName: String { "GPTK \(version)" }
}

/// Keeps imported toolkits in ~/Library/Application Support/GPTKPatcher/Toolkits/<version>/.
/// Each folder holds the toolkit's `external/` and `wine/` directories plus a small `toolkit.json`.
enum ToolkitLibrary {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/GPTKPatcher/Toolkits", isDirectory: true)
    }

    private struct Manifest: Codable {
        var version: String
        var importedAt: Date
        var minimumOS: String?
        var sourceName: String?
    }

    static func list() -> [Toolkit] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        let toolkits: [Toolkit] = names.compactMap { name in
            guard !name.hasPrefix(".") else { return nil }   // an import in progress, or one that never finished
            let lib = directory.appendingPathComponent(name, isDirectory: true)
            guard GPTKSource.isValidLib(lib) else { return nil }
            let manifest = readManifest(in: lib)
            let info = D3DMetalInfo.read(inLib: lib)
            let attrs = try? fm.attributesOfItem(atPath: lib.path)
            return Toolkit(
                version: manifest?.version ?? info.version ?? name,
                lib: lib,
                importedAt: manifest?.importedAt ?? (attrs?[.creationDate] as? Date) ?? .distantPast,
                minimumOS: manifest?.minimumOS ?? info.minimumOS,
                sourceName: manifest?.sourceName)
        }
        return toolkits.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }

    /// Mounts the image, copies its payload into the library and returns the stored toolkit.
    /// A version that is already in the library is returned as-is without copying again.
    static func importImage(_ dmg: URL, log: (String) -> Void) throws -> Toolkit {
        let payload = try GPTKSource.locate(dmg: dmg, log: log)
        defer { payload.detachAll(log: log) }

        let fm = FileManager.default
        let target = directory.appendingPathComponent(payload.version, isDirectory: true)
        if GPTKSource.isValidLib(target) {
            log("GPTK \(payload.version) is already in the library.")
            return list().first { $0.version == payload.version }
                ?? Toolkit(version: payload.version, lib: target, importedAt: Date(), minimumOS: payload.minimumOS, sourceName: dmg.lastPathComponent)
        }

        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(".importing-\(payload.version)", isDirectory: true)
        if fm.fileExists(atPath: staging.path) { try fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            log("Copying GPTK \(payload.version) into the library…")
            try Shell.check("/bin/cp", ["-Rp", payload.lib.path + "/.", staging.path])
            try Shell.check("/bin/chmod", ["-R", "u+w", staging.path])
            Quarantine.strip(under: staging)
            let manifest = Manifest(version: payload.version, importedAt: Date(), minimumOS: payload.minimumOS, sourceName: dmg.lastPathComponent)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(manifest).write(to: staging.appendingPathComponent("toolkit.json"))
            copyAppleDocuments(from: payload.documentsRoot, into: staging, log: log)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.moveItem(at: staging, to: target)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        log("Added GPTK \(payload.version) to the library at \(target.path)")
        return Toolkit(version: payload.version, lib: target, importedAt: Date(), minimumOS: payload.minimumOS, sourceName: dmg.lastPathComponent)
    }

    /// Apple ships a licence, acknowledgements and read-me beside the redistributable files.
    /// They are kept with the imported copy so the terms travel with the toolkit.
    static let documentsFolder = "Apple Toolkit Documents"

    private static func copyAppleDocuments(from root: URL?, into staging: URL, log: (String) -> Void) {
        let fm = FileManager.default
        guard let root,
              let names = try? fm.contentsOfDirectory(atPath: root.path) else { return }
        let wanted = names.filter { name in
            !name.hasPrefix(".") && ["rtf", "txt", "pdf"].contains((name as NSString).pathExtension.lowercased())
        }
        guard !wanted.isEmpty else { return }
        let folder = staging.appendingPathComponent(documentsFolder, isDirectory: true)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            for name in wanted.sorted() {
                try fm.copyItem(at: root.appendingPathComponent(name), to: folder.appendingPathComponent(name))
            }
            log("Kept Apple's \(wanted.sorted().joined(separator: ", ")) with the toolkit")
        } catch {
            log("Note: could not copy Apple's toolkit documents (\(error.localizedDescription))")
        }
    }

    static func remove(_ toolkit: Toolkit) throws {
        guard toolkit.lib.path.hasPrefix(directory.path) else { return }
        try FileManager.default.removeItem(at: toolkit.lib)
    }

    private static func readManifest(in lib: URL) -> Manifest? {
        guard let data = try? Data(contentsOf: lib.appendingPathComponent("toolkit.json")) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Manifest.self, from: data)
    }
}
