import Foundation

enum PatchMode: String, Sendable, CaseIterable {
    case copy, inPlace
}

/// Everything a patch needs, captured before the job starts so later UI changes cannot affect it.
struct PatchRequest: Sendable {
    let crossOver: CrossOverBundle
    let toolkit: Toolkit
    let mode: PatchMode
    /// Where the copy goes (`.copy` mode). For `.inPlace` this is the source app itself.
    let destination: URL
    /// Applications folder an in-place patched app is moved into when it lives somewhere like Downloads.
    let applicationsFolder: URL
    let replaceExisting: Bool
    let graphics: GraphicsSettings
    let bottles: [BottleEnv.Bottle]
}

struct PatchReceipt: Codable {
    let tool: String
    let date: Date
    let sourceCrossOver: String
    let sourceCrossOverVersion: String
    let stockD3DMetalVersion: String?
    let toolkitSource: String?
    let toolkitPath: String
    let gptkD3DMetalVersion: String
    let gptkDirectory: String
    let stockBackup: String
    let dlssAliases: [String]
    let environment: [String: String]
}

/// Coarse phases of a patch, reported to the UI as they start. These are real boundaries in
/// `PatchJob.run`, not a timer.
enum PatchStep: Int, CaseIterable, Sendable {
    case verifying, checkingToolkit, copying, installing, finalizing, signing

    /// The source is verified before copying; the modified app is verified after signing.
    static func sequence(for mode: PatchMode) -> [PatchStep] {
        [.checkingToolkit, .verifying, .copying, .installing, .finalizing, .signing]
    }

    func title(for mode: PatchMode) -> String {
        switch self {
        case .verifying: return "Verifying CrossOver"
        case .checkingToolkit: return "Checking the toolkit"
        case .copying: return mode == .copy ? "Copying CrossOver" : "Preparing CrossOver"
        case .installing: return "Installing toolkit components"
        case .finalizing: return "Applying settings"
        case .signing: return "Signing and verifying the patched app"
        }
    }
}

/// Swaps a CrossOver's bundled GPTK (`apple_gptk`) for a toolkit from the library, in a duplicate
/// or in the app itself. The stored toolkit is validated before anything is touched, the stock
/// `apple_gptk` is kept as `apple_gptk.stock`, and a failure part-way restores what was there.
struct PatchJob {
    static var toolVersion: String {
        guard Bundle.main.bundleIdentifier == "com.macprotips.CrossOverGPTKPatcher" else { return "development" }
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
    }
    let request: PatchRequest
    let log: (String) -> Void
    var onStep: (PatchStep) -> Void = { _ in }
    var token = CancellationToken()

    private let fm = FileManager.default
    private let aliasPrefix = "nvngx-on-metalfx."

    init(request: PatchRequest, log: @escaping (String) -> Void, onStep: @escaping (PatchStep) -> Void = { _ in }, token: CancellationToken = CancellationToken()) {
        self.request = request
        self.log = log
        self.onStep = onStep
        self.token = token
    }

    /// Runs the whole job. If a step fails or the job is cancelled, a duplicate created during
    /// this run is removed and an in-place app gets its toolkit folder put back.
    func run() throws -> URL {
        let lock = try OperationLock()
        defer { lock.unlock() }
        let backup = try FileBackup()
        var createdCopy: URL?
        var replacedCopy: (original: URL, trashed: URL)?
        var rollback: (() -> [String])?
        do {
            return try perform(createdCopy: &createdCopy, replacedCopy: &replacedCopy, rollback: &rollback, backup: backup)
        } catch {
            var failures = rollback?() ?? []
            failures += backup.restore()
            if let createdCopy, FileSafety.exists(createdCopy) {
                do {
                    try fm.removeItem(at: createdCopy)
                    log("Removed the unfinished copy.")
                } catch { failures.append("Could not remove \(createdCopy.path): \(error.localizedDescription)") }
            }
            if let replacedCopy {
                do { try fm.moveItem(at: replacedCopy.trashed, to: replacedCopy.original) }
                catch { failures.append("The replaced app remains in the Trash at \(replacedCopy.trashed.path).") }
            }
            if !failures.isEmpty {
                backup.keepForRecovery()
                failures.forEach(log)
                throw PatchError.io("\(error.localizedDescription) Recovery needs attention: \(failures.joined(separator: " "))")
            }
            log("Rolled back the patch's file changes.")
            throw error
        }
    }

    private func perform(createdCopy: inout URL?, replacedCopy: inout (original: URL, trashed: URL)?,
                         rollback: inout (() -> [String])?, backup: FileBackup) throws -> URL {
        let src = try CrossOverBundle(url: request.crossOver.url)
        try src.requireFirstLaunchApproval()
        log("GPTK Patcher \(Self.toolVersion) · \(ProcessInfo.processInfo.operatingSystemVersionString) · mode: \(request.mode.rawValue)")
        log("\(src.displayVersion) (build \(src.build)) at \(src.url.path)")
        if request.mode == .copy { try Self.validateDestination(request.destination, source: src.url) }
        else { try src.requireNotRunning() }
        if src.hasARM64Wine { log("This build has ARM64 Wine too; the toolkit's D3DMetal only serves Intel (x86_64) bottles.") }
        if let stock = src.installedD3DMetalVersion { log("Stock D3DMetal in that build: \(stock)") }
        log("Graphics settings: \(request.graphics.summary)")

        // 1. Make sure the stored toolkit is intact before touching anything.
        onStep(.checkingToolkit)
        try token.checkpoint()
        let toolkit = request.toolkit
        try GPTKSource.validateLib(toolkit.lib)
        guard FileSafety.isSafeComponent(toolkit.version) else { throw PatchError.notGPTK("invalid version") }
        if let issue = toolkit.compatibilityIssue { throw PatchError.io(issue) }
        let installedVersion = D3DMetalInfo.read(inLib: toolkit.lib).version ?? toolkit.version
        log("Toolkit: GPTK \(toolkit.version) (D3DMetal \(installedVersion)) from the library")
        guard FileSafety.isSafeComponent(installedVersion) else { throw PatchError.notGPTK("invalid D3DMetal version") }
        let patchedBefore = fm.fileExists(atPath: src.sharedSupport.appendingPathComponent("gptkpatcher-receipt.json").path)
        if patchedBefore {
            log("This CrossOver was patched before; the stock toolkit kept back then stays as the backup.")
        } else if let stock = src.installedD3DMetalVersion, stock == installedVersion {
            log("Note: this CrossOver already ships D3DMetal \(stock); it will carry the same build plus the nvngx aliases.")
        }
        onStep(.verifying)
        try AppSigning.validateSource(src, token: token, log: log)

        // 2. Duplicate CrossOver (an APFS clone when possible, which is instant and shares storage),
        //    or work on the source app itself.
        onStep(.copying)
        try token.checkpoint()
        let dst: URL
        switch request.mode {
        case .copy:
            dst = request.destination
            replacedCopy = try prepareDestination(dst)
            createdCopy = dst
            try copyBundle(from: src.url, to: dst)
        case .inPlace:
            dst = src.url
            log("Patching \(src.url.lastPathComponent) in place.")
        }
        let copy = try CrossOverBundle(url: dst)
        let gptkDir = try copy.gptkDirectory()
        let stockBackup = gptkDir.deletingLastPathComponent().appendingPathComponent("apple_gptk.stock")
        try FileSafety.requireContained(stockBackup, in: dst)

        // 3. Swap apple_gptk.
        onStep(.installing)
        try token.checkpoint()
        log("GPTK directory: \(gptkDir.path)")
        if fm.isDirectory(gptkDir.deletingLastPathComponent().appendingPathComponent("apple_gptk3")) {
            log("This build also bundles GPTK 3 (apple_gptk3). It is left alone; bottles set to D3DMetal 3 (CX_GRAPHICS_BACKEND_VERSION=3) keep using it, all others use the patched toolkit.")
        }
        var previousPatch: URL?
        if fm.fileExists(atPath: stockBackup.path) {
            // Patched before: the real stock is already backed up and the current folder is an
            // earlier patch. Set it aside until the new one is verified.
            log("Found an earlier patch; keeping the original \(stockBackup.lastPathComponent)")
            let previous = gptkDir.deletingLastPathComponent().appendingPathComponent(".apple_gptk.previous")
            guard !FileSafety.exists(previous) else {
                throw PatchError.io("An interrupted patch left recovery files at \(previous.path). Keep that folder and restore it as apple_gptk before retrying, or start from a fresh CrossOver download.")
            }
            try fm.moveItem(at: gptkDir, to: previous)
            previousPatch = previous
            rollback = { restore(previous, to: gptkDir, what: "previous") }
        } else {
            try fm.moveItem(at: gptkDir, to: stockBackup)
            log("Kept the stock GPTK as \(stockBackup.lastPathComponent)")
            rollback = { restore(stockBackup, to: gptkDir, what: "stock") }
        }

        try fm.createDirectory(at: gptkDir, withIntermediateDirectories: false)
        log("Copying GPTK \(toolkit.version) files from the library…")
        try Shell.check("/bin/cp", ["-Rp", toolkit.lib.path + "/.", gptkDir.path], token: token)
        try? fm.removeItem(at: gptkDir.appendingPathComponent("toolkit.json"))
        try? fm.removeItem(at: gptkDir.appendingPathComponent(ToolkitLibrary.documentsFolder))
        try Shell.check("/bin/chmod", ["-R", "u+w", gptkDir.path], token: token)
        let stripped = try Quarantine.strip(under: gptkDir, token: token)
        if stripped > 0 { log("Removed the quarantine flag from \(stripped) copied item(s)") }

        // 4. Make sure nothing CrossOver relies on went missing, then add the DLSS aliases.
        try carryOverLooseExternalFiles(stock: stockBackup, new: gptkDir)
        reportMissingWineFiles(stock: stockBackup, new: gptkDir)
        let aliases = try createNvngxAliases(in: gptkDir)
        if aliases.isEmpty {
            log("Warning: no \(aliasPrefix)* files were found, so no nvngx aliases were created.")
        }

        // 5. Verify and record what happened.
        onStep(.finalizing)
        try token.checkpoint()
        try verify(gptkDir: gptkDir, expectAliases: !aliases.isEmpty)
        let receipt = PatchReceipt(
            tool: "GPTKPatcher " + Self.toolVersion, date: Date(),
            sourceCrossOver: src.url.path, sourceCrossOverVersion: src.version,
            stockD3DMetalVersion: D3DMetalInfo.read(inLib: stockBackup).version ?? src.installedD3DMetalVersion,
            toolkitSource: toolkit.sourceName, toolkitPath: toolkit.lib.path, gptkD3DMetalVersion: installedVersion,
            gptkDirectory: String(gptkDir.path.dropFirst(dst.path.count + 1)),
            stockBackup: String(stockBackup.path.dropFirst(dst.path.count + 1)), dlssAliases: aliases,
            environment: Dictionary(uniqueKeysWithValues: request.graphics.assignments.compactMap { key, value in value.map { (key, $0) } }))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let receiptURL = copy.sharedSupport.appendingPathComponent("gptkpatcher-receipt.json")
        try FileSafety.requireContained(receiptURL, in: dst)
        try backup.capture(receiptURL)
        try encoder.encode(receipt).write(to: receiptURL, options: .atomic)
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: dst.path)

        // 6. Environment: app-wide in the copy's etc/CrossOver.conf, then per bottle on top.
        let settings = request.graphics
        if settings.storeInCopy {
            let conf = copy.globalConfig
            try FileSafety.requireContained(conf, in: dst)
            if fm.fileExists(atPath: conf.path) {
                try backup.capture(conf)
                try backup.capture(conf.appendingPathExtension("gptkpatcher.bak"))
                let changes = try settings.apply(to: conf)
                log("App-wide settings: \(settings.describe(changes)) in etc/CrossOver.conf")
            } else {
                throw PatchError.io("CrossOver.conf is missing. DLSS settings cannot be installed. Use a fresh CrossOver download.")
            }
        }
        for bottle in request.bottles {
            try token.checkpoint()
            try backup.capture(bottle.conf)
            try backup.capture(bottle.conf.appendingPathExtension("gptkpatcher.bak"))
            let changes = try settings.apply(to: bottle.conf)
            log("Bottle “\(bottle.name)”: \(settings.describe(changes)) in cxbottle.conf")
        }

        onStep(.signing)
        // Repatching's temporary backup is inside the bundle: remove it before sealing, but
        // keep it in the transaction directory until success so signing can still roll back.
        if let previousPatch {
            let kept = backup.directory.appendingPathComponent("previous-toolkit")
            try fm.moveItem(at: previousPatch, to: kept)
            rollback = { restore(kept, to: gptkDir, what: "previous") }
        }
        try AppSigning.seal(copy, backup: backup, token: token, log: log)
        try token.checkpoint()
        rollback = nil

        // 7. In-place patches get the toolkit version in their name, like duplicates do. CrossOver's
        //    helpers find it by bundle identifier, so the rename is safe; a taken name is left alone.
        //    Preflight requires its bottle sessions to be stopped before files or paths change.
        var finalURL = dst
        if request.mode == .inPlace {
            let wanted = "\(src.name) (GPTK \(installedVersion)).app"
            let target = dst.deletingLastPathComponent().appendingPathComponent(wanted)
            if dst.lastPathComponent == wanted {
                log("Name already carries the toolkit version.")
            } else if fm.fileExists(atPath: target.path) {
                log("Kept the name \(dst.lastPathComponent): \(wanted) already exists in that folder.")
            } else {
                do {
                    try fm.moveItem(at: dst, to: target)
                    finalURL = target
                    log("Renamed to \(wanted)")
                } catch {
                    log("Kept the name \(dst.lastPathComponent): rename failed (\(error.localizedDescription)).")
                }
            }
        }

        // 8. A CrossOver patched where it was downloaded belongs in Applications, as CrossOver itself
        //    offers on first launch. Move it there unless something with that name is already there.
        if request.mode == .inPlace, !isInApplicationsFolder(finalURL) {
            let target = request.applicationsFolder.appendingPathComponent(finalURL.lastPathComponent)
            if fm.fileExists(atPath: target.path) {
                log("Left in \(finalURL.deletingLastPathComponent().path): \(target.lastPathComponent) already exists in \(request.applicationsFolder.path).")
            } else {
                do {
                    try fm.createDirectory(at: request.applicationsFolder, withIntermediateDirectories: true)
                    try fm.moveItem(at: finalURL, to: target)
                    finalURL = target
                    log("Moved to \(target.path)")
                } catch {
                    log("Left in \(finalURL.deletingLastPathComponent().path): move failed (\(error.localizedDescription)).")
                }
            }
        }

        log("Done. \(finalURL.lastPathComponent) now carries D3DMetal \(installedVersion).")
        return finalURL
    }

    // MARK: - Rollback

    /// Puts the set-aside toolkit folder back in place of the half-installed one.
    private func restore(_ kept: URL, to gptkDir: URL, what: String) -> [String] {
        do {
            if fm.fileExists(atPath: gptkDir.path) { try fm.removeItem(at: gptkDir) }
            try fm.moveItem(at: kept, to: gptkDir)
            log("Restored the \(what) toolkit folder.")
            return []
        } catch {
            return ["Couldn't restore the \(what) toolkit folder: \(error.localizedDescription). It is still at \(kept.path)."]
        }
    }

    // MARK: - Steps

    private func isInApplicationsFolder(_ url: URL) -> Bool {
        let parent = url.deletingLastPathComponent().standardizedFileURL.path
        let home = fm.homeDirectoryForCurrentUser.path
        return parent == "/Applications" || parent == home + "/Applications"
    }

    static func validateDestination(_ destination: URL, source: URL) throws {
        let dst = destination.resolvingSymlinksInPath().standardizedFileURL
        let src = source.resolvingSymlinksInPath().standardizedFileURL
        guard destination.pathExtension.lowercased() == "app", dst != src,
              !FileSafety.contains(dst, in: src), !FileSafety.contains(src, in: dst) else {
            throw PatchError.io("Choose a separate .app destination outside the original CrossOver. A duplicate cannot replace or contain its source.")
        }
        guard (try? destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw PatchError.io("The destination is a symbolic link. Choose a new app name.")
        }
    }

    private func prepareDestination(_ dst: URL) throws -> (original: URL, trashed: URL)? {
        let parent = dst.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        guard FileSafety.exists(dst) else { return nil }
        guard request.replaceExisting else { throw PatchError.destinationExists(dst.path) }
        // Refuse to replace anything that isn't a CrossOver bundle, so a typo can't wipe an unrelated app.
        try CrossOverBundle(url: dst).requireNotRunning()
        log("Moving the existing \(dst.lastPathComponent) to the Trash…")
        var trashed: NSURL?
        try fm.trashItem(at: dst, resultingItemURL: &trashed)
        guard let trashed else { throw PatchError.io("The replaced app was moved to the Trash, but its recovery path could not be read.") }
        return (dst, trashed as URL)
    }

    private func copyBundle(from src: URL, to dst: URL) throws {
        log("Copying \(src.lastPathComponent) → \(dst.path)")
        let clone = try Shell.run("/bin/cp", ["-cRp", src.path, dst.path], token: token)
        try token.checkpoint()
        if clone.status != 0 {
            log("APFS clone failed (\(clone.stderr.trimmingCharacters(in: .whitespacesAndNewlines))); copying normally…")
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try Shell.check("/usr/bin/ditto", [src.path, dst.path], token: token)
        }
        guard (try? dst.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true else {
            try? fm.removeItem(at: dst)
            throw PatchError.io("\(src.lastPathComponent) is a link to another app rather than the app itself. Drop in the real CrossOver.app.")
        }
        guard fm.fileExists(atPath: dst.appendingPathComponent("Contents/MacOS").path) else {
            throw PatchError.io("The copy at \(dst.path) is incomplete.")
        }
    }

    /// CrossOver ships loose helpers next to D3DMetal.framework (for example libd3dshared.dylib).
    /// If a toolkit build doesn't include one of them, bring the stock file along rather than break the loader.
    private func carryOverLooseExternalFiles(stock: URL, new: URL) throws {
        let stockExternal = stock.appendingPathComponent("external")
        let newExternal = new.appendingPathComponent("external")
        guard let items = try? fm.contentsOfDirectory(atPath: stockExternal.path) else { return }
        for name in items where !name.hasPrefix(".") {
            let target = newExternal.appendingPathComponent(name)
            guard !fm.fileExists(atPath: target.path) else { continue }
            try fm.copyItem(at: stockExternal.appendingPathComponent(name), to: target)
            log("Carried over external/\(name) from the stock GPTK (not present in the toolkit image)")
        }
    }

    private func reportMissingWineFiles(stock: URL, new: URL) {
        for sub in ["wine/x86_64-windows", "wine/x86_64-unix"] {
            let before = Set((try? fm.contentsOfDirectory(atPath: stock.appendingPathComponent(sub).path)) ?? [])
            let after = Set((try? fm.contentsOfDirectory(atPath: new.appendingPathComponent(sub).path)) ?? [])
            let missing = before.subtracting(after).filter { !$0.hasPrefix(".") && !$0.hasPrefix("nvngx.") }.sorted()
            if !missing.isEmpty {
                log("Note: \(sub) in the toolkit lacks \(missing.joined(separator: ", ")) that the stock build had.")
            }
        }
    }

    /// GPTK ships its DLSS shim as `nvngx-on-metalfx.dll` / `.so`. Games ask for `nvngx.dll`,
    /// so provide copies under that name while leaving the originals in place.
    private func createNvngxAliases(in gptkDir: URL) throws -> [String] {
        var created: [String] = []
        for sub in ["wine/x86_64-windows", "wine/x86_64-unix"] {
            let dir = gptkDir.appendingPathComponent(sub)
            guard let items = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in items.sorted() where name.hasPrefix(aliasPrefix) {
                let alias = "nvngx." + name.dropFirst(aliasPrefix.count)
                let target = dir.appendingPathComponent(alias)
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                try fm.copyItem(at: dir.appendingPathComponent(name), to: target)
                created.append("\(sub)/\(alias)")
                log("DLSS: \(sub)/\(name) → \(alias)")
            }
        }
        return created
    }

    private func verify(gptkDir: URL, expectAliases: Bool) throws {
        let required = [
            "external/D3DMetal.framework/Versions/A/D3DMetal",
            "external/D3DMetal.framework/D3DMetal",
            "wine/x86_64-windows/d3d12.dll",
            "wine/x86_64-windows/dxgi.dll",
        ]
        for rel in required where !fm.fileExists(atPath: gptkDir.appendingPathComponent(rel).path) {
            throw PatchError.io("Verification failed: \(rel) is missing from \(gptkDir.path)")
        }
        if expectAliases, !fm.fileExists(atPath: gptkDir.appendingPathComponent("wine/x86_64-windows/nvngx.dll").path) {
            throw PatchError.io("Verification failed: wine/x86_64-windows/nvngx.dll was not created")
        }
        let installed = D3DMetalInfo.read(inLib: gptkDir).version ?? "unknown"
        log("Verified: D3DMetal \(installed) is in place with the DirectX 12 and DXGI shims.")
    }
}
