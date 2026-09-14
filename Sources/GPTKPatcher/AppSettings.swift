import Foundation

struct GraphicsOptions: Equatable, Sendable {
    var fpsEnabled = false
    var fpsValue = 60
    var hud = false
    var metal4 = Metal4Mode.automatic
    /// DXMT options other than its frame limiter that this config file sets itself. They are
    /// written back with every cap change, and survive a reset.
    var dxmtOptions: [String] = []
    /// The same, from the app defaults this file inherits. DXMT reads one string, so a bottle that
    /// sets a cap replaces the whole inherited value; these are carried along so nothing else the
    /// app-wide config asked for is lost for that bottle.
    var inheritedDXMTOptions: [String] = []

    static func load(from conf: URL, inheriting defaults: URL? = nil) -> GraphicsOptions {
        func effective(_ key: String) -> String? {
            CXConfig.value(of: key, in: conf) ?? defaults.flatMap { CXConfig.value(of: key, in: $0) }
        }
        let dxmt = effective("DXMT_CONFIG")
        let cap = effective("D3DM_MAX_FPS").flatMap(Int.init) ?? DXMTConfig.frameRate(in: dxmt) ?? 0
        let own = DXMTConfig.otherOptions(in: CXConfig.value(of: "DXMT_CONFIG", in: conf))
        let ownKeys = Set(own.map(DXMTConfig.key))
        let inherited = defaults.map { DXMTConfig.otherOptions(in: CXConfig.value(of: "DXMT_CONFIG", in: $0)) } ?? []
        return GraphicsOptions(fpsEnabled: cap > 0, fpsValue: cap > 0 ? cap : 60,
                               hud: effective("MTL_HUD_ENABLED") == "1",
                               metal4: Metal4Mode.from(stored: CXConfig.value(of: "D3DM_MTL4", in: conf)),
                               dxmtOptions: own,
                               inheritedDXMTOptions: inherited.filter { !ownKeys.contains(DXMTConfig.key($0)) })
    }

    func changes(from saved: GraphicsOptions) -> [(String, String?)] {
        var result: [(String, String?)] = []
        if fpsEnabled != saved.fpsEnabled || (fpsEnabled && fpsValue != saved.fpsValue) {
            // One cap, both translation layers: D3DMetal games read the first, DXMT games the second.
            result.append(("D3DM_MAX_FPS", fpsEnabled ? String(fpsValue) : "0"))
            result.append(("DXMT_CONFIG", DXMTConfig.string(keeping: inheritedDXMTOptions + dxmtOptions,
                                                            frameRate: fpsEnabled ? fpsValue : 0)))
        }
        if hud != saved.hud { result.append(("MTL_HUD_ENABLED", hud ? "1" : "0")) }
        if metal4 != saved.metal4 { result.append(("D3DM_MTL4", metal4.storedValue)) }
        return result
    }

    /// Clearing this config's overrides: the keys this app owns go away, but DXMT options someone
    /// set here by hand are not this app's to delete, so they are written back without the cap.
    func reset() -> [(String, String?)] {
        AppSettings.keys.map { key in
            key == "DXMT_CONFIG" && !dxmtOptions.isEmpty ? (key, dxmtOptions.joined(separator: ";")) : (key, nil)
        }
    }
}

enum AppSettings {
    static let keys = ["D3DM_MAX_FPS", "DXMT_CONFIG", "MTL_HUD_ENABLED", "D3DM_MTL4"]

    static func apply(_ changes: [(String, String?)], to app: CrossOverBundle, bottleConfig: URL? = nil) throws {
        guard !changes.isEmpty else { return }
        let lock = try OperationLock()
        defer { lock.unlock() }
        let conf = bottleConfig ?? app.globalConfig
        if bottleConfig == nil {
            try FileSafety.requireContained(conf, in: app.url)
            try app.requireNotRunning()
        }
        let backup = try FileBackup()
        try backup.capture(conf)
        try backup.capture(conf.appendingPathExtension("gptkpatcher.bak"))
        do {
            let changed = try CXConfig.apply(changes, to: conf)
            if bottleConfig == nil, !changed.isEmpty {
                try AppSigning.seal(app, backup: backup, log: { _ in })
            }
        } catch {
            let failures = backup.restore()
            if !failures.isEmpty { throw PatchError.io("\(error.localizedDescription) \(failures.joined(separator: " "))") }
            throw error
        }
    }
}
