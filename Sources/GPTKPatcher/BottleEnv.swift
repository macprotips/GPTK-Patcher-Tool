import Foundation

/// Reads and edits the `[EnvironmentVariables]` section of CrossOver `.conf` files.
/// The same format is used by a bottle's `cxbottle.conf` and by the app-wide
/// `Contents/SharedSupport/CrossOver/etc/CrossOver.conf`; CrossOver's launcher applies
/// the app-wide file first and the bottle file on top of it.
enum CXConfig {
    static let section = "[EnvironmentVariables]"

    /// CrossOver's parser is case-insensitive and lets a later line override an earlier one.
    static func value(of key: String, in conf: URL) -> String? {
        guard let text = try? String(contentsOf: conf, encoding: .utf8) else { return nil }
        var inSection = false
        var found: String?
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { inSection = isSectionHeader(trimmed); continue }
            guard inSection, let (k, v) = parseAssignment(trimmed), k.caseInsensitiveCompare(key) == .orderedSame else { continue }
            found = v
        }
        return found
    }

    private static func isSectionHeader(_ line: String) -> Bool {
        line.caseInsensitiveCompare(section) == .orderedSame
    }

    /// Sets `"key" = "value"`; a `nil` value removes the key. Creates the section when needed.
    /// The first edit of a file keeps a `<name>.gptkpatcher.bak` copy next to it.
    /// Returns true when the file changed.
    @discardableResult
    static func set(_ key: String, to value: String?, in conf: URL) throws -> Bool {
        let original = try String(contentsOf: conf, encoding: .utf8)
        var lines = original.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")

        let header: Int
        if let existingHeader = lines.firstIndex(where: { isSectionHeader($0.trimmingCharacters(in: .whitespaces)) }) {
            header = existingHeader
        } else {
            guard value != nil else { return false }
            // Append the section at the end, separated from the previous one by a blank line.
            if !(lines.last ?? "").isEmpty { lines.append("") }
            if lines.count >= 2, !lines[lines.count - 2].isEmpty { lines.insert("", at: lines.count - 1) }
            lines.insert(section, at: lines.count - 1)
            header = lines.count - 2
        }

        var end = lines.count
        for i in (header + 1)..<lines.count where lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("[") {
            end = i
            break
        }
        // Every line for the key; CrossOver honours the last one, so that is the one kept.
        let matches = ((header + 1)..<end).filter {
            parseAssignment(lines[$0].trimmingCharacters(in: .whitespaces))?.0.caseInsensitiveCompare(key) == .orderedSame
        }
        let duplicates = matches.dropLast()

        if let value {
            let assignment = "\"\(key)\" = \"\(value)\""
            if let existing = matches.last {
                if lines[existing].trimmingCharacters(in: .whitespaces) == assignment, duplicates.isEmpty { return false }
                lines[existing] = assignment
            } else {
                var insertAt = end
                while insertAt > header + 1, lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty { insertAt -= 1 }
                lines.insert(assignment, at: insertAt)
            }
            for index in duplicates.reversed() { lines.remove(at: index) }
        } else {
            guard !matches.isEmpty else { return false }
            for index in matches.reversed() { lines.remove(at: index) }
        }

        try backupOnce(conf)
        try lines.joined(separator: "\n").write(to: conf, atomically: true, encoding: .utf8)
        return true
    }

    private static func backupOnce(_ conf: URL) throws {
        let backup = conf.appendingPathExtension("gptkpatcher.bak")
        if !FileManager.default.fileExists(atPath: backup.path) {
            try FileManager.default.copyItem(at: conf, to: backup)
        }
    }

    /// `"Key" = "Value"`, optionally followed by a `; comment`.
    private static func parseAssignment(_ line: String) -> (String, String)? {
        guard line.hasPrefix("\""), let eq = line.range(of: "=") else { return nil }
        let key = line[..<eq.lowerBound].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        var rest = line[eq.upperBound...].trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("\""), let close = rest.dropFirst().firstIndex(of: "\"") {
            rest = String(rest[rest.index(after: rest.startIndex)..<close])
        } else if let comment = rest.firstIndex(of: ";") {
            rest = rest[..<comment].trimmingCharacters(in: .whitespaces)
        }
        return key.isEmpty ? nil : (key, rest)
    }
}

enum BottleEnv {
    static var bottlesDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CrossOver/Bottles")
    }

    struct Bottle: Identifiable, Hashable, Sendable {
        let name: String
        let conf: URL
        var id: String { name }
    }

    static func listBottles() -> [Bottle] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: bottlesDirectory.path) else { return [] }
        return names.sorted().compactMap { name in
            let conf = bottlesDirectory.appendingPathComponent(name).appendingPathComponent("cxbottle.conf")
            return fm.fileExists(atPath: conf.path) ? Bottle(name: name, conf: conf) : nil
        }
    }

    /// A bottle with Wine processes still alive: its wineserver, and/or programs left over from a
    /// session (they survive the server and keep the environment they were launched with).
    struct RunningBottle: Sendable {
        let prefix: URL
        let serverPID: Int32?
        let wineserver: String?
        /// The CrossOver the session was started from (its SharedSupport/CrossOver folder), if known.
        let cxRoot: String?
        let clientPIDs: [Int32]

        /// True when that CrossOver no longer exists at that path (moved or renamed). Programs from
        /// any CrossOver then hang talking to this session.
        var isStale: Bool { cxRoot.map { !FileManager.default.fileExists(atPath: $0) } ?? false }
    }

    private struct Server { let pid: Int32; let binary: String; let prefix: URL; let cxRoot: String? }

    private static func servers() -> [Server] {
        guard let list = try? Shell.run("/bin/ps", ["-axo", "pid=,comm="]) else { return [] }
        var found: [Server] = []
        for line in list.stdout.split(separator: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            guard parts.count == 2, parts[1].hasSuffix("/wineserver"), let pid = Int32(parts[0]) else { continue }
            guard let env = try? Shell.run("/bin/ps", ["-E", "-p", String(pid), "-o", "command="]),
                  let range = env.stdout.range(of: #"WINEPREFIX=(.+?)(?= [A-Za-z_][A-Za-z0-9_]*=|$)"#, options: .regularExpression) else { continue }
            let prefix = env.stdout[range].dropFirst("WINEPREFIX=".count).trimmingCharacters(in: .whitespacesAndNewlines)
            var cxRoot: String?
            if let rootRange = env.stdout.range(of: #"CX_ROOT=(.+?)(?= [A-Za-z_][A-Za-z0-9_]*=|$)"#, options: .regularExpression) {
                cxRoot = env.stdout[rootRange].dropFirst("CX_ROOT=".count).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            found.append(Server(pid: pid, binary: String(parts[1]), prefix: URL(fileURLWithPath: prefix).standardizedFileURL, cxRoot: cxRoot))
        }
        return found
    }

    /// Wine client processes (Windows programs and Wine helpers) that belong to a bottle: they
    /// don't expose their environment, but their working directory or an open file (the program
    /// itself, DLLs) lies inside the bottle, which `lsof` can report.
    private static func clientPIDs(inPrefix prefix: URL) -> [Int32] {
        guard let list = try? Shell.run("/bin/ps", ["-axo", "pid=,comm="]) else { return [] }
        var pids: [Int32] = []
        let me = getpid()
        for line in list.stdout.split(separator: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let pid = Int32(parts[0]), pid != me else { continue }
            let command = parts[1].lowercased()
            if command.hasSuffix(".exe") || (command.contains("wine") && !command.hasSuffix("/wineserver")) { pids.append(pid) }
        }
        guard !pids.isEmpty,
              let out = try? Shell.run("/usr/sbin/lsof", ["-Fpn", "-p", pids.map(String.init).joined(separator: ",")]) else { return [] }
        let root = prefix.path
        var matched = Set<Int32>()
        var current: Int32?
        for line in out.stdout.split(separator: "\n") {
            if line.hasPrefix("p") { current = Int32(line.dropFirst()) }
            else if line.hasPrefix("n"), let pid = current {
                let path = line.dropFirst()
                if path == root || path.hasPrefix(root + "/") { matched.insert(pid) }
            }
        }
        return matched.sorted()
    }

    /// CrossOver's launcher apps for a bottle (the "Steam" icon in the Dock, for example) live in
    /// ~/Applications/CrossOver/<bottle>/ and keep running as "Menu Helper" while the program runs.
    private static func launcherPIDs(forBottleNamed name: String) -> [Int32] {
        guard let list = try? Shell.run("/bin/ps", ["-axo", "pid=,comm="]) else { return [] }
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/CrossOver/\(name)/").path
        var pids: [Int32] = []
        for line in list.stdout.split(separator: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let pid = Int32(parts[0]), parts[1].hasPrefix(folder) else { continue }
            pids.append(pid)
        }
        return pids
    }

    static func runningBottle(for bottle: Bottle) -> RunningBottle? {
        let prefix = bottle.conf.deletingLastPathComponent().standardizedFileURL
        let server = servers().first { $0.prefix == prefix }
        let clients = clientPIDs(inPrefix: prefix) + launcherPIDs(forBottleNamed: bottle.name)
        guard server != nil || !clients.isEmpty else { return nil }
        return RunningBottle(prefix: prefix, serverPID: server?.pid, wineserver: server?.binary, cxRoot: server?.cxRoot, clientPIDs: clients)
    }

    static func runningBottles() -> [RunningBottle] {
        listBottles().compactMap(runningBottle(for:))
    }

    /// Bottle sessions started from the given CrossOver app. After that app is renamed or moved
    /// they become stale, so they are ended before an in-place patch renames the app.
    static func runningBottles(startedFrom app: URL) -> [RunningBottle] {
        let root = app.appendingPathComponent("Contents/SharedSupport/CrossOver").standardizedFileURL.path
        return runningBottles().filter { $0.cxRoot.map { URL(fileURLWithPath: $0).standardizedFileURL.path == root } ?? false }
    }

    /// Ends everything in the bottle the way CrossOver's own Quit does, then makes sure of it.
    /// The server is asked to stop its clients politely, then hard; whatever survives that (or was
    /// already orphaned) is ended directly, identified by the files it holds inside the bottle.
    /// Process ids are looked up afresh here: the snapshot may be minutes old.
    static func quit(_ running: RunningBottle) throws {
        if let server = servers().first(where: { $0.prefix == running.prefix }) {
            let pid = server.pid
            let env = ["WINEPREFIX": running.prefix.path]
            if FileManager.default.isExecutableFile(atPath: server.binary) {
                _ = try? Shell.run(server.binary, ["-k15"], environment: env)
                if !waitForExit(pid, seconds: 8) {
                    _ = try? Shell.run(server.binary, ["-k"], environment: env)
                    _ = waitForExit(pid, seconds: 4)
                }
            }
            if kill(pid, 0) == 0 { kill(pid, SIGKILL); _ = waitForExit(pid, seconds: 2) }
        }
        var leftovers = clientPIDs(inPrefix: running.prefix) + launcherPIDs(forBottleNamed: running.prefix.lastPathComponent)
        for pid in leftovers { kill(pid, SIGTERM) }
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline, leftovers.contains(where: { kill($0, 0) == 0 }) { Thread.sleep(forTimeInterval: 0.25) }
        leftovers = leftovers.filter { kill($0, 0) == 0 }
        for pid in leftovers { kill(pid, SIGKILL) }
        _ = leftovers.allSatisfy { waitForExit($0, seconds: 2) }
    }

    private static func waitForExit(_ pid: Int32, seconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if kill(pid, 0) != 0 { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return kill(pid, 0) != 0
    }
}

/// How a bottle handles Metal 4 in D3DMetal. D3DMetal reads `D3DM_MTL4` once per process with
/// `atoi`, so only an explicit value is reliable: an absent variable means "default", which on
/// macOS 27 with GPTK 4 is on. Turning it off requires writing "0", not removing the line.
enum Metal4Mode: String, CaseIterable, Identifiable {
    case automatic, on, off
    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "Default"
        case .on: return "On"
        case .off: return "Off"
        }
    }

    /// The value to store, or nil to remove the line.
    var storedValue: String? {
        switch self {
        case .automatic: return nil
        case .on: return "1"
        case .off: return "0"
        }
    }

    static func from(stored: String?) -> Metal4Mode {
        guard let stored else { return .automatic }
        return (Int(stored.trimmingCharacters(in: .whitespaces)) ?? 0) != 0 ? .on : .off
    }

    /// What "Default" means on the running macOS, matching D3DMetal 4's own rule.
    static var defaultDescription: String {
        let running = ProcessInfo.processInfo.operatingSystemVersion
        return running.majorVersion >= 27
            ? "Default is on with GPTK 4 on macOS \(running.majorVersion). Choose Off to turn it off; removing the line does not."
            : "Metal 4 needs macOS 27; on this Mac it stays off."
    }
}

/// The D3DMetal switches this app manages. Each maps to one environment variable.
struct GraphicsSettings: Sendable, Equatable {
    var fpsCap: Int? = nil
    var metalHUD = false
    var storeInCopy = true

    /// key → value; a nil value leaves whatever the file already has. DLSS → MetalFX is always on.
    var assignments: [(key: String, value: String?)] {
        [("D3DM_ENABLE_METALFX", "1"),
         ("DXMT_ENABLE_NVEXT", "1"),
         ("D3DM_MAX_FPS", fpsCap.map(String.init)),
         ("MTL_HUD_ENABLED", metalHUD ? "1" : nil)]
    }

    var summary: String {
        "DLSS → MetalFX on" + (fpsCap.map { ", cap \($0) fps" } ?? "") + (metalHUD ? ", Metal HUD on" : "")
    }

    /// Human-readable outcome of `apply`.
    func describe(_ changes: [String]) -> String {
        changes.isEmpty ? "already set" : changes.joined(separator: ", ")
    }

    /// Writes the settings into one config file and reports what changed. Existing values for
    /// switches this request doesn't set (a cap set earlier from the options popover) are kept.
    func apply(to conf: URL) throws -> [String] {
        var changes: [String] = []
        for (key, value) in assignments {
            guard let value else { continue }
            if try CXConfig.set(key, to: value, in: conf) { changes.append("\(key)=\(value)") }
        }
        return changes
    }
}
