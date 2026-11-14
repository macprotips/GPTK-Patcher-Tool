import AppKit

/// The Mac's own Steam, which NotProton runs games through: the installed games and their
/// launch options. Steam keeps launch options in memory and writes them back on quit, so they
/// can only be changed here while it is closed.
enum Steam {
    struct Game: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
    }

    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Steam")
    }

    static let bundleIdentifier = "com.valvesoftware.steam"

    static var running: [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
    }

    /// Every installed game, by name.
    static func games(root: URL = root) -> [Game] {
        let fm = FileManager.default
        let folders = (try? String(contentsOf: root.appendingPathComponent("config/libraryfolders.vdf"), encoding: .utf8))
            .map { VDF.values(of: "path", in: $0) } ?? []
        var found: [Game] = []
        for library in Set(folders + [root.path]).sorted() {
            let apps = URL(fileURLWithPath: library).appendingPathComponent("steamapps")
            for file in (try? fm.contentsOfDirectory(atPath: apps.path)) ?? [] where file.hasPrefix("appmanifest_") {
                guard let manifest = try? String(contentsOf: apps.appendingPathComponent(file), encoding: .utf8),
                      let id = VDF.values(of: "appid", in: manifest).first,
                      let name = VDF.values(of: "name", in: manifest).first,
                      // Steam's shared runtime installs like a game and is not one.
                      !name.hasPrefix("Steamworks Common"),
                      !found.contains(where: { $0.id == id }) else { continue }
                found.append(Game(id: id, name: name))
            }
        }
        return found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The signed-in account's settings: the one Steam wrote most recently.
    static func localConfig(root: URL = root) -> URL? {
        let fm = FileManager.default
        let userdata = root.appendingPathComponent("userdata")
        return ((try? fm.contentsOfDirectory(atPath: userdata.path)) ?? [])
            .map { userdata.appendingPathComponent($0).appendingPathComponent("config/localconfig.vdf") }
            .compactMap { url in
                (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date).map { (url, $0) }
            }
            .max { $0.1 < $1.1 }?.0
    }

    /// Each game's launch options, empty where it has none.
    static func launchOptions(for games: [Game], config: URL? = localConfig()) -> [String: String] {
        guard let config, let text = try? String(contentsOf: config, encoding: .utf8) else { return [:] }
        return Dictionary(uniqueKeysWithValues: games.map { ($0.id, VDF.launchOptions(for: $0.id, in: text) ?? "") })
    }

    /// Each game's D3DMetal cap, read from its launch options. 0 is none.
    static func frameCaps(for games: [Game], config: URL? = localConfig()) -> [String: Int] {
        launchOptions(for: games, config: config).mapValues(FrameCap.current(in:))
    }

    /// Rewrites games' launch options in one write. The first change keeps a backup beside the
    /// file.
    static func editLaunchOptions(_ edits: [(app: String, edit: (String) -> String)], config: URL? = localConfig(),
                                  steamIsRunning: Bool = !running.isEmpty) throws {
        guard !steamIsRunning else { throw PatchError.io("Quit Steam first. It overwrites launch options changed while it is open.") }
        guard let config, let text = try? String(contentsOf: config, encoding: .utf8) else {
            throw PatchError.io("Steam's settings were not found. Open Steam and sign in once.")
        }
        var edited = text
        for (app, edit) in edits {
            let options = edit(VDF.launchOptions(for: app, in: edited) ?? "")
            guard let next = VDF.settingLaunchOptions(options, for: app, in: edited) else {
                throw PatchError.io("Steam's settings are not laid out as expected, so nothing was changed.")
            }
            edited = next
        }
        let backup = config.appendingPathExtension("gptkpatcher.bak")
        if !FileSafety.exists(backup) { try FileManager.default.copyItem(at: config, to: backup) }
        try edited.write(to: config, atomically: true, encoding: .utf8)
    }
}
