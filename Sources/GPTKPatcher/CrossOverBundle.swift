import AppKit

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
        guard url.pathExtension.lowercased() == "app", fm.isDirectory(url) else {
            throw PatchError.notCrossOver("expected an .app bundle")
        }
        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        try FileSafety.requireContained(infoURL, in: url)
        guard let info = NSDictionary(contentsOf: infoURL) as? [String: Any] else {
            throw PatchError.notCrossOver("no readable Contents/Info.plist")
        }
        let identifier = (info["CFBundleIdentifier"] as? String) ?? ""
        guard identifier.caseInsensitiveCompare("com.codeweavers.CrossOver") == .orderedSame else {
            throw PatchError.notCrossOver("bundle identifier is \(identifier.isEmpty ? "missing" : identifier)")
        }
        guard fm.isDirectory(url.appendingPathComponent("Contents/SharedSupport/CrossOver")) else {
            throw PatchError.notCrossOver("Contents/SharedSupport/CrossOver is missing")
        }
        self.url = url
        self.identifier = identifier
        let name = (info["CFBundleName"] as? String) ?? url.deletingPathExtension().lastPathComponent
        guard FileSafety.isSafeComponent(name) else { throw PatchError.notCrossOver("invalid app name") }
        self.name = name
        self.version = (info["CFBundleShortVersionString"] as? String) ?? "?"
        self.build = (info["CFBundleVersion"] as? String) ?? "?"
        self.isPreview = name.localizedCaseInsensitiveContains("preview")
        let shared = url.appendingPathComponent("Contents/SharedSupport/CrossOver")
        try FileSafety.requireContained(shared, in: url)
        self.hasARM64Wine = fm.isDirectory(shared.appendingPathComponent("lib/wine/aarch64-unix"))
    }

    /// True for an app GPTK Patcher patched: its receipt says so, and an original that a patch
    /// replaced is still kept inside the app as `.stock`. A patch can replace the toolkit, DXMT,
    /// MoltenVK or any mix of them, so any one of those backups counts.
    var hasPatchBackup: Bool {
        guard let data = try? Data(contentsOf: url.appendingPathComponent(PatchedAppRegistry.receiptPath)),
              let receipt = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (receipt["tool"] as? String)?.hasPrefix("GPTKPatcher ") == true else { return false }
        if receipt["gptkD3DMetalVersion"] is String, let directory = try? gptkDirectory(),
           FileManager.default.isDirectory(directory.appendingPathExtension("stock")) { return true }
        // The receipt records each backup relative to the app.
        var kept = [receipt["stockBackup"], receipt["dxmtStock"]].compactMap { $0 as? String }
        kept += ((receipt["moltenVKSlots"] as? [String]) ?? []).map { $0 + ".stock" }
        return kept.contains { relative in
            let backup = url.appendingPathComponent(relative)
            return FileSafety.contains(backup, in: url) && FileSafety.exists(backup)
        }
    }

    func executableURL() throws -> URL {
        let info = try Data(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
        guard let plist = try PropertyListSerialization.propertyList(from: info, format: nil) as? [String: Any],
              let name = plist["CFBundleExecutable"] as? String, FileSafety.isSafeComponent(name) else {
            throw PatchError.notCrossOver("invalid main executable")
        }
        let executable = url.appendingPathComponent("Contents/MacOS").appendingPathComponent(name).resolvingSymlinksInPath()
        try FileSafety.requireContained(executable, in: url)
        return executable
    }

    func requireNotRunning() throws {
        let active = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).contains { app in
            guard !app.isTerminated, let path = app.bundleURL else { return false }
            if path.resolvingSymlinksInPath().standardizedFileURL == url.standardizedFileURL { return true }
            // A never-opened download runs from a hidden translocated copy, whose path is a random
            // one and never matches. Such a copy is this app only if its build matches too:
            // matching on the file name alone refuses to patch whenever any CrossOver of that name
            // is running, including an unrelated one.
            return path.path.contains("/AppTranslocation/")
                && path.lastPathComponent == url.lastPathComponent
                && (Bundle(url: path)?.infoDictionary?["CFBundleVersion"] as? String) == build
        }
        guard let running = BottleEnv.processesUsingApp(url) else {
            if active { try explainRunning([]) }
            throw PatchError.io("Couldn't check whether \(url.lastPathComponent) is running, so nothing was changed. Quit it and any games or bottles it opened, then try again.")
        }
        if active || !running.isEmpty { try explainRunning(running) }
    }

    /// Programs Wine runs for a bottle itself, not for anything the user opened.
    private static let bottleServices: Set<String> = [
        "services.exe", "plugplay.exe", "svchost.exe", "winedevice.exe", "rpcss.exe",
        "explorer.exe", "conhost.exe", "rundll32.exe", "tabtip.exe", "wineserver",
    ]

    /// Throws the reason a patch has to wait, from what is still running from this app.
    func explainRunning(_ running: [BottleEnv.AppProcess]) throws {
        let name = url.deletingPathExtension().lastPathComponent
        let programs = running.filter { !Self.bottleServices.contains($0.name.lowercased()) }
        if !running.isEmpty, programs.isEmpty {
            // A bottle keeps its services for a few seconds after the last program quits. Ones
            // still there minutes later lost their wineserver and stay until they are quit.
            if running.allSatisfy({ $0.seconds > 120 }) {
                throw PatchError.leftoverServices(app: name, pids: running.map(\.pid))
            }
            throw PatchError.io("A \(name) bottle is still closing in the background. Wait a few seconds, then try again.")
        }
        // Naming them matters: "quit CrossOver" is no help when what is holding the app is a
        // program left behind by a bottle.
        let names = Array(Set(programs.map(\.name))).sorted()
        let list = names.isEmpty ? "" : " Still running: " + names.prefix(4).joined(separator: ", ")
            + (names.count > 4 ? ", and \(names.count - 4) more." : ".")
        throw PatchError.io("Quit \(name) and any games or bottles it opened, then try again.\(list)")
    }

    /// Used when selecting a source and again immediately before patching. Never launches it.
    func requireFirstLaunchApproval() throws {
        if try Quarantine.hasPendingApproval(at: url) { throw PatchError.firstLaunchRequired }
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
            if fm.isDirectory(candidate) {
                try FileSafety.requireContained(candidate, in: url)
                return candidate
            }
        }
        throw PatchError.unsupportedLayout("neither lib64/apple_gptk nor lib/apple_gptk exists in \(sharedSupport.path). This CrossOver build has no D3DMetal support to replace.")
    }

    /// Every libMoltenVK.dylib the build ships. CrossOver 26 keeps one in `lib64`; CrossOver
    /// Preview keeps a thin copy per architecture under `lib/x86_64` and `lib/aarch64`.
    func moltenVKSlots() -> [URL] {
        let fm = FileManager.default
        let candidates = ["lib64", "lib/x86_64", "lib/aarch64", "lib"].map {
            sharedSupport.appendingPathComponent($0).appendingPathComponent(MoltenVKLibrary.dylibName)
        }
        return candidates.filter { fm.fileExists(atPath: $0.path) }
    }

    /// False when macOS refuses changes to this app because App Management has not been allowed.
    /// Opening a file for writing and closing it changes nothing, and is enough to be refused.
    var allowsChanges: Bool {
        let descriptor = open(url.appendingPathComponent("Contents/Info.plist").path, O_WRONLY)
        guard descriptor >= 0 else { return errno != EPERM }
        close(descriptor)
        return true
    }

    var installedD3DMetalVersion: String? {
        guard let dir = try? gptkDirectory() else { return nil }
        return D3DMetalInfo.read(inLib: dir).version
    }

    /// The release DXMT was built from, which it carries as a tag like `v0.72-25-gf35d839`.
    var installedDXMTVersion: String? {
        let dll = sharedSupport.appendingPathComponent("lib/dxmt/x86_64-windows/d3d11.dll")
        guard let data = try? Data(contentsOf: dll, options: .mappedIfSafe) else { return nil }
        let text = String(decoding: data, as: Unicode.ASCII.self)
        let tag = try? NSRegularExpression(pattern: #"\x00v(\d+\.\d+(?:\.\d+)?)(?:-\d+-g[0-9a-f]+)?\x00"#)
        guard let match = tag?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
