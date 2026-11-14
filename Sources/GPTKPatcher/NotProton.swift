import AppKit
import CryptoKit

/// NotProton runs Windows Steam games in the macOS Steam client, out of a runner it copies from
/// a CrossOver app. What matters here, from its source:
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

    static func hasSupportFolder(at directory: URL = supportDirectory) -> Bool {
        FileManager.default.isDirectory(directory)
    }

    /// The app itself, or the folder it leaves once it has been run.
    static var isInstalled: Bool { appURL != nil || hasSupportFolder() }

    static let bundleIdentifier = "com.notproton.NotProton"
    private static let locatedKey = "notProtonAppPath"

    /// A NotProton the user pointed at, for a copy Launch Services has not indexed.
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
        sha256(of: app.appendingPathComponent(sharedSupport).appendingPathComponent(loader))
    }

    private static let sharedSupport = "Contents/SharedSupport/CrossOver"
    private static let loader = "lib/wine/x86_64-unix/wine"

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

    static var runnersDirectory: URL {
        supportDirectory.appendingPathComponent("runners")
    }

    /// The builds NotProton holds a runner for, as it names them (`27.0.0.41073`,
    /// `27.0.0.41073-fex`). A name with a `+` is assembled from another and is left out.
    static func linkedBuilds(in directory: URL = runnersDirectory) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name in
            guard name.hasPrefix("crossover-"), !name.contains("+") else { return nil }
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
                let patched = root.appendingPathComponent(loader)
                let original = patched.appendingPathExtension("notproton-orig")
                return sha256(of: FileSafety.exists(original) ? original : patched) == hash
            }
    }

    /// The CrossOver apps NotProton has a runner for: the first of each build in its own order,
    /// which is the one it copies from.
    static func linkedApps(in roots: [URL] = searchRoots, runners directory: URL = runnersDirectory) -> [URL] {
        var seen: Set<String> = []
        return discovered(in: roots).filter { app in
            guard let hash = loaderHash(ofApp: app), seen.insert(hash).inserted else { return false }
            return !runners(for: app, in: directory).isEmpty
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

    /// Copies what a patch put in `app` into NotProton's copies of it, leaving what NotProton
    /// patched there alone. Runs under NotProton's installation lock and is refused while a game
    /// is running. Every file is copied before any is swapped, and a failed swap puts back the
    /// ones already made. False when NotProton has no copy.
    static func update(from app: URL, in directory: URL = runnersDirectory,
                       isRunning: (URL) -> Bool = NotProton.isRunning) throws -> Bool {
        let fm = FileManager.default
        let source = app.appendingPathComponent(sharedSupport)
        guard let receipt = PatchReceipt.read(source.appendingPathComponent(PatchedAppRegistry.receiptName)) else { return false }

        // The lock NotProton takes for set-up and Reinstall: the folder its own sits in.
        let lock = open(directory.deletingLastPathComponent().deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            if lock >= 0 { close(lock) }
            throw PatchError.io("NotProton is changing its files. Wait for it to finish, then try again.")
        }
        defer { flock(lock, LOCK_UN); close(lock) }

        // Looked up under the lock, so a runner NotProton was removing is not written to.
        let runners = runners(for: app, in: directory)
        guard !runners.isEmpty else { return false }
        let busy = PatchError.io("A game is still running through NotProton. Quit it, then try again.")
        guard !runners.contains(where: isRunning) else { throw busy }

        let prefix = sharedSupport + "/"
        var paths = [receipt.gptkDirectory, receipt.stockBackup, receipt.dxmtStock].compactMap { $0 }
        if receipt.dxmtStock != nil { paths.append(prefix + "lib/dxmt") }
        for slot in receipt.moltenVKSlots ?? [] { paths += [slot, slot + ".stock"] }
        let items = paths.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
            + [PatchedAppRegistry.receiptName]

        struct Swap { let staged, target, old: URL }
        var swaps: [Swap] = []
        defer { swaps.forEach { try? fm.removeItem(at: $0.staged) } }
        for runner in runners {
            for item in items where FileSafety.exists(source.appendingPathComponent(item)) {
                let target = runner.appendingPathComponent(item)
                try FileSafety.requireContained(target, in: runner)
                let folder = target.deletingLastPathComponent()
                // Only what the runner already has room for: no folder is created in it.
                guard fm.isDirectory(folder) else { continue }
                let swap = Swap(staged: folder.appendingPathComponent(".\(target.lastPathComponent).new"), target: target,
                                old: folder.appendingPathComponent(".\(target.lastPathComponent).old"))
                try? fm.removeItem(at: swap.staged)
                swaps.append(swap)
                try fm.copyItem(at: source.appendingPathComponent(item), to: swap.staged)
                // As NotProton does to what it copies.
                for marker in ["com.apple.quarantine", "com.apple.provenance"] {
                    _ = try? Shell.run("/usr/bin/xattr", ["-r", "-d", marker, swap.staged.path])
                }
            }
        }
        // Asked again, since copying takes a while and a game may have started.
        guard !runners.contains(where: isRunning) else { throw busy }

        var made: [Swap] = []
        do {
            for swap in swaps {
                try? fm.removeItem(at: swap.old)
                if FileSafety.exists(swap.target) { try fm.moveItem(at: swap.target, to: swap.old) }
                made.append(swap)
                try fm.moveItem(at: swap.staged, to: swap.target)
            }
        } catch {
            for swap in made.reversed() {
                try? fm.removeItem(at: swap.target)
                if FileSafety.exists(swap.old) { try? fm.moveItem(at: swap.old, to: swap.target) }
            }
            throw error
        }
        swaps.forEach { try? fm.removeItem(at: $0.old) }
        return true
    }

    /// True when one of NotProton's copies of `app` does not carry the patch the app has.
    static func isBehind(_ app: URL, runners: [URL]) -> Bool {
        guard let patch = try? Data(contentsOf: app.appendingPathComponent(PatchedAppRegistry.receiptPath)) else { return false }
        return runners.contains { (try? Data(contentsOf: $0.appendingPathComponent(PatchedAppRegistry.receiptName))) != patch }
    }

    /// Whether the D3DMetal games will run reads D3DM_MAX_FPS: NotProton's copy when it has one,
    /// otherwise the app. D3DMetal 3 does not have it.
    static func hasFrameCap(_ app: URL, runners: [URL]) -> Bool {
        let root = runners.first ?? app.appendingPathComponent(sharedSupport)
        return ["lib64", "lib"].contains { hasFrameCap(toolkit: root.appendingPathComponent("\($0)/apple_gptk")) }
    }

    /// Whether the D3DMetal in a toolkit folder reads D3DM_MAX_FPS.
    static func hasFrameCap(toolkit folder: URL) -> Bool {
        let binary = folder.appendingPathComponent("external/D3DMetal.framework/Versions/A/D3DMetal")
        return (try? Data(contentsOf: binary, options: .mappedIfSafe))?.range(of: Data("D3DM_MAX_FPS".utf8)) != nil
    }
}
