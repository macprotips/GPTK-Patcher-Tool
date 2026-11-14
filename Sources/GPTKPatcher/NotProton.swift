import AppKit
import CryptoKit

/// NotProton runs Windows Steam games in the macOS Steam client, out of a runner it copies from
/// a CrossOver app. What matters here, from its source (CrossOverSource, CrossOverRow,
/// RunnerInstaller):
///
/// - A build is recognised by the SHA-256 of `lib/wine/x86_64-unix/wine`. Patching leaves that
///   file and ntdll.dll alone, so a patched CrossOver is still a supported build.
/// - Set-up copies the whole SharedSupport/CrossOver folder into the runner, then patches the
///   loader and ntdll.dll there. Only Reinstall copies it again, so `update` carries a later
///   patch across.
/// - One row per build: of several same-build apps in /Applications or ~/Applications the first
///   in its order wins and the rest cannot be picked (NotProtonNot/NotProton#279).
/// - CrossOver.conf and cxbottle.conf are never read, so settings written there do not apply.
enum NotProton {
    static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/notproton")
    }

    /// True when NotProton's support folder exists.
    static func isInstalled(at directory: URL = supportDirectory) -> Bool {
        FileManager.default.isDirectory(directory)
    }

    /// The app itself, or the folder it leaves once it has been run.
    static var isInstalled: Bool { appURL != nil || isInstalled() }

    static let bundleIdentifier = "com.notproton.NotProton"
    private static let locatedKey = "notProtonAppPath"

    /// A NotProton the person pointed at, for a copy Launch Services has not indexed.
    static var locatedApp: URL? {
        guard let path = UserDefaults.standard.string(forKey: locatedKey),
              FileManager.default.isDirectory(URL(fileURLWithPath: path)) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Remembers it. False when the app is not NotProton.
    static func locate(_ app: URL) -> Bool {
        guard Bundle(url: app)?.bundleIdentifier == bundleIdentifier else { return false }
        UserDefaults.standard.set(app.path, forKey: locatedKey)
        return true
    }

    static var appURL: URL? {
        locatedApp ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    /// Where NotProton looks for CrossOver without being told.
    static var searchRoots: [URL] {
        [URL(fileURLWithPath: "/Applications"),
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
    }

    /// The file NotProton fingerprints to tell builds apart.
    static func loaderHash(ofApp app: URL) -> String? {
        sha256(of: app.appendingPathComponent("Contents/SharedSupport/CrossOver/lib/wine/x86_64-unix/wine"))
    }

    private static func sha256(of file: URL) -> String? {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Every CrossOver NotProton finds by itself, in its order: Preview first, then by name.
    /// The first of each build is the one it lists.
    static func discovered(in roots: [URL] = searchRoots) -> [URL] {
        let fm = FileManager.default
        var found: [URL] = []
        for root in roots {
            let entries = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for entry in entries where entry.pathExtension == "app"
                && entry.deletingPathExtension().lastPathComponent.hasPrefix("CrossOver")
                && fm.isDirectory(entry.appendingPathComponent("Contents/SharedSupport/CrossOver/lib/wine")) {
                found.append(entry.resolvingSymlinksInPath())
            }
        }
        func name(_ url: URL) -> String { url.deletingPathExtension().lastPathComponent }
        func isPreview(_ url: URL) -> Bool { name(url).localizedCaseInsensitiveContains("Preview") }
        return found.sorted { a, b in
            if isPreview(a) != isPreview(b) { return isPreview(a) }
            if name(a) != name(b) { return name(a) < name(b) }
            return a.path < b.path
        }
    }

    /// The same-build CrossOver NotProton lists ahead of `app`, or nil when `app` is the one.
    static func usedInstead(of app: URL, in roots: [URL] = searchRoots) -> URL? {
        let app = app.resolvingSymlinksInPath()
        guard let hash = loaderHash(ofApp: app) else { return nil }
        guard let winner = discovered(in: roots).first(where: { loaderHash(ofApp: $0) == hash }) else { return nil }
        return winner.path == app.path ? nil : winner
    }

    static var runnersDirectory: URL {
        supportDirectory.appendingPathComponent("runners")
    }

    /// The builds NotProton holds a runner for, as it names them (`27.0.0.41073`,
    /// `27.0.0.41073-fex`). A name with a `+` is assembled from another and is left out.
    static func linkedBuilds(in directory: URL = runnersDirectory) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name in
            guard name.hasPrefix("crossover-"), !name.contains("+"), !name.hasPrefix(".") else { return nil }
            return String(name.dropFirst("crossover-".count))
        }.sorted()
    }

    /// NotProton's copies of this CrossOver: the runners whose loader, as it was before
    /// NotProton patched it, is the app's. The ARM64 Preview shares a version number with the
    /// regular one, so the number alone cannot tell them apart.
    static func runners(for app: URL, in directory: URL = runnersDirectory) -> [URL] {
        guard let hash = loaderHash(ofApp: app) else { return [] }
        return linkedBuilds(in: directory)
            .map { directory.appendingPathComponent("crossover-\($0)/CrossOver") }
            .filter { root in
                let loader = root.appendingPathComponent("lib/wine/x86_64-unix/wine")
                let original = loader.appendingPathExtension("notproton-orig")
                return sha256(of: FileSafety.exists(original) ? original : loader) == hash
            }
    }

    /// True while a game or Wine tool runs from this runner or from a game launcher, as
    /// NotProton checks before it removes one. Unknown counts as running.
    static func isRunning(from runner: URL) -> Bool {
        guard let result = try? Shell.run("/bin/ps", ["-axww", "-o", "comm="]), result.status == 0 else { return true }
        let support = runner.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let prefixes = [runner.deletingLastPathComponent().path + "/", support.appendingPathComponent("launchers").path + "/"]
        return result.stdout.split(separator: "\n").contains { line in
            prefixes.contains { line.trimmingCharacters(in: .whitespaces).hasPrefix($0) }
        }
    }

    /// Copies what a patch put in `app` into NotProton's copies of it, which leaves them as
    /// NotProton's Reinstall would, without undoing what NotProton patched there. Held under
    /// NotProton's own installation lock, staged in full before anything is swapped, and refused
    /// while a game is running. False when NotProton has no copy.
    static func update(from app: URL, in directory: URL = runnersDirectory,
                       isRunning: (URL) -> Bool = NotProton.isRunning) throws -> Bool {
        let fm = FileManager.default
        let prefix = "Contents/SharedSupport/CrossOver/"
        let source = app.appendingPathComponent(prefix)
        guard let data = try? Data(contentsOf: source.appendingPathComponent(receiptName)),
              let receipt = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        let runners = runners(for: app, in: directory)
        guard !runners.isEmpty else { return false }

        // The lock NotProton takes for set-up and Reinstall: its support folder itself.
        let lock = open(directory.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            if lock >= 0 { close(lock) }
            throw PatchError.io("NotProton is changing its files. Wait for it to finish, then try again.")
        }
        defer { flock(lock, LOCK_UN); close(lock) }
        guard !runners.contains(where: isRunning) else {
            throw PatchError.io("A game is still running through NotProton. Quit it, then try again.")
        }

        var paths = [receipt["gptkDirectory"], receipt["stockBackup"], receipt["dxmtStock"]].compactMap { $0 as? String }
        if receipt["dxmtStock"] is String { paths.append(prefix + "lib/dxmt") }
        for slot in receipt["moltenVKSlots"] as? [String] ?? [] { paths += [slot, slot + ".stock"] }
        let items = paths.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) } + [receiptName]

        // Every copy is made first, beside what it replaces, so running out of space changes nothing.
        var swaps: [(staged: URL, target: URL)] = []
        defer { swaps.forEach { try? fm.removeItem(at: $0.staged) } }
        for runner in runners {
            for item in items where FileSafety.exists(source.appendingPathComponent(item)) {
                let target = runner.appendingPathComponent(item)
                try FileSafety.requireContained(target, in: runner)
                let staged = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).new")
                try? fm.removeItem(at: staged)
                try fm.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
                swaps.append((staged, target))
                try fm.copyItem(at: source.appendingPathComponent(item), to: staged)
                // As NotProton does to what it copies.
                for marker in ["com.apple.quarantine", "com.apple.provenance"] {
                    _ = try? Shell.run("/usr/bin/xattr", ["-r", "-d", marker, staged.path])
                }
            }
        }
        for swap in swaps {
            let old = swap.target.deletingLastPathComponent().appendingPathComponent(".\(swap.target.lastPathComponent).old")
            try? fm.removeItem(at: old)
            let replaces = FileSafety.exists(swap.target)
            if replaces { try fm.moveItem(at: swap.target, to: old) }
            do {
                try fm.moveItem(at: swap.staged, to: swap.target)
            } catch {
                if replaces { try? fm.moveItem(at: old, to: swap.target) }
                throw error
            }
            try? fm.removeItem(at: old)
        }
        return true
    }

    private static let receiptName = "gptkpatcher-receipt.json"

    /// True when NotProton has a copy of this CrossOver and its patch is not the one in `app`.
    static func isBehind(_ app: URL, in directory: URL = runnersDirectory) -> Bool {
        guard let patch = try? Data(contentsOf: app.appendingPathComponent("Contents/SharedSupport/CrossOver/" + receiptName)) else { return false }
        return runners(for: app, in: directory).contains {
            (try? Data(contentsOf: $0.appendingPathComponent(receiptName))) != patch
        }
    }

    /// Whether the D3DMetal games will run reads D3DM_MAX_FPS: NotProton's copy when it has one,
    /// otherwise the app. D3DMetal 3 does not have it.
    static func hasFrameCap(_ app: URL, in directory: URL = runnersDirectory) -> Bool {
        let root = runners(for: app, in: directory).first ?? app.appendingPathComponent("Contents/SharedSupport/CrossOver")
        return ["lib64", "lib"].contains { parent in
            let binary = root.appendingPathComponent("\(parent)/apple_gptk/external/D3DMetal.framework/Versions/A/D3DMetal")
            return (try? Data(contentsOf: binary, options: .mappedIfSafe))?.range(of: Data("D3DM_MAX_FPS".utf8)) != nil
        }
    }
}
