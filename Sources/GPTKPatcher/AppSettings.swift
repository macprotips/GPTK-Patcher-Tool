import Foundation

struct GraphicsOptions: Equatable, Sendable {
    var fpsEnabled = false
    var fpsValue = 60
    var hud = false
    var metal4 = Metal4Mode.automatic

    static func load(from conf: URL, inheriting defaults: URL? = nil) -> GraphicsOptions {
        func effective(_ key: String) -> String? {
            CXConfig.value(of: key, in: conf) ?? defaults.flatMap { CXConfig.value(of: key, in: $0) }
        }
        let cap = effective("D3DM_MAX_FPS").flatMap(Int.init) ?? 0
        return GraphicsOptions(fpsEnabled: cap > 0, fpsValue: cap > 0 ? cap : 60,
                               hud: effective("MTL_HUD_ENABLED") == "1",
                               metal4: Metal4Mode.from(stored: CXConfig.value(of: "D3DM_MTL4", in: conf)))
    }

    func changes(from saved: GraphicsOptions) -> [(String, String?)] {
        var result: [(String, String?)] = []
        if fpsEnabled != saved.fpsEnabled || (fpsEnabled && fpsValue != saved.fpsValue) {
            result.append(("D3DM_MAX_FPS", fpsEnabled ? String(fpsValue) : "0"))
        }
        if hud != saved.hud { result.append(("MTL_HUD_ENABLED", hud ? "1" : "0")) }
        if metal4 != saved.metal4 { result.append(("D3DM_MTL4", metal4.storedValue)) }
        return result
    }
}

enum AppSettings {
    static let keys = ["D3DM_MAX_FPS", "MTL_HUD_ENABLED", "D3DM_MTL4"]

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
