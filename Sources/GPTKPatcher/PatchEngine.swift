import AppKit
import Foundation
import Observation

enum DropStatus: Equatable {
    case empty
    case checking(String)
    case ok(String)
    case failed(String)
}

struct Failure: Equatable {
    let title: String
    let message: String
}

enum Phase: Equatable {
    case idle
    case running(PatchStep)
    case done(URL)
    case failed(Failure)
    case cancelled
}

@MainActor
@Observable
final class PatchEngine {
    /// One engine for the window and for files opened via the Dock or Finder.
    static let shared = PatchEngine()

    var crossOver: CrossOverBundle?
    var crossOverURL: URL?
    var crossOverStatus: DropStatus = .empty

    var toolkits: [Toolkit] = []
    var selectedToolkit: Toolkit?
    var importingImage: URL?
    var toolkitStatus: DropStatus = .empty
    var gptkVersion: String? { selectedToolkit?.version }

    var patchedApps: [PatchedApp] = []

    private static let modeKey = "patchMode"
    var mode: PatchMode = PatchMode(rawValue: UserDefaults.standard.string(forKey: PatchEngine.modeKey) ?? "") ?? .copy {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey) }
    }

    var phase: Phase = .idle
    var logLines: [String] = []

    private static let folderKey = "outputFolder"
    /// /Applications, alongside the user's other apps, unless it isn't writable for this account.
    private static var defaultFolder: URL {
        let system = URL(fileURLWithPath: "/Applications", isDirectory: true)
        if FileManager.default.isWritableFile(atPath: system.path) { return system }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
    }

    /// Where the copy goes. Remembered between launches; falls back to the default folder if the
    /// remembered one is gone.
    var outputFolder: URL {
        didSet { if persistsOutputFolder { UserDefaults.standard.set(outputFolder.path, forKey: Self.folderKey) } }
    }
    private var persistsOutputFolder = true
    private var token: CancellationToken?

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.folderKey).map { URL(fileURLWithPath: $0) }
        if let saved, FileManager.default.isDirectory(saved) {
            outputFolder = saved
        } else {
            outputFolder = Self.defaultFolder
        }
    }

    /// Uses a folder for this launch only, without remembering it (used by the QA hooks).
    func useTemporaryOutputFolder(_ url: URL) {
        persistsOutputFolder = false
        outputFolder = url
    }

    var isRunning: Bool { if case .running = phase { return true } else { return false } }
    var isReady: Bool { crossOver != nil && selectedToolkit != nil && importingImage == nil && !isRunning }

    /// The name the copy will get. Never replaces anything: if the name is taken, a counter is added.
    var outputName: String {
        let base = "\(crossOver?.name ?? "CrossOver") (GPTK \(gptkVersion ?? "…"))"
        var candidate = base + ".app"
        var n = 2
        while FileManager.default.fileExists(atPath: outputFolder.appendingPathComponent(candidate).path) {
            candidate = "\(base) \(n).app"
            n += 1
        }
        return candidate
    }

    var outputURL: URL { outputFolder.appendingPathComponent(outputName) }

    var graphics: GraphicsSettings {
        GraphicsSettings(storeInCopy: true)
    }

    // MARK: Inputs

    /// Takes file URLs from the pasteboard (⌘V after copying in Finder) and routes them like a drop.
    @discardableResult
    func pasteFromPasteboard() -> Int {
        let urls = (NSPasteboard.general.readObjects(forClasses: [NSURL.self],
                                                     options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        var accepted = 0
        for url in urls where route(url) { accepted += 1 }
        return accepted
    }

    /// Sends any dropped or chosen file to the right slot, whichever tile it landed on.
    @discardableResult
    func route(_ url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "app": setCrossOver(url); return true
        case "dmg": importToolkit(from: url); return true
        default: return false
        }
    }

    func setCrossOver(_ url: URL) {
        crossOverURL = url
        if case .cancelled = phase { phase = .idle }
        do {
            let bundle = try CrossOverBundle(url: url)
            crossOver = bundle
            var lines = [bundle.displayVersion]
            if let stock = bundle.installedD3DMetalVersion { lines.append("D3DMetal \(stock)") }
            if bundle.hasARM64Wine { lines.append("GPTK applies to Intel bottles only") }
            crossOverStatus = .ok(lines.joined(separator: "\n"))
        } catch {
            crossOver = nil
            crossOverStatus = .failed(Self.reason(for: error))
        }
    }

    func clearCrossOver() {
        crossOver = nil
        crossOverURL = nil
        crossOverStatus = .empty
    }

    func refreshPatchedApps() {
        patchedApps = PatchedAppRegistry.load()
    }

    // MARK: Toolkit library

    func refreshToolkits() {
        toolkits = ToolkitLibrary.list()
        if let selected = selectedToolkit, let match = toolkits.first(where: { $0.version == selected.version }) {
            selectedToolkit = match
        } else {
            selectedToolkit = toolkits.first
        }
        if toolkits.isEmpty, case .ok = toolkitStatus { toolkitStatus = .empty }
    }

    func selectToolkit(_ toolkit: Toolkit) {
        selectedToolkit = toolkit
        toolkitStatus = .ok(toolkit.version)
    }

    /// Copies the image's payload into the library, then selects it.
    func importToolkit(from url: URL) {
        importingImage = url
        toolkitStatus = .checking("Adding to the library…")
        if case .cancelled = phase { phase = .idle }
        Task.detached(priority: .userInitiated) {
            let result: Result<Toolkit, Error> = Result { try ToolkitLibrary.importImage(url) { _ in } }
            await MainActor.run {
                guard self.importingImage == url else { return }
                switch result {
                case .success(let toolkit):
                    self.importingImage = nil
                    self.refreshToolkits()
                    self.selectedToolkit = self.toolkits.first { $0.version == toolkit.version } ?? toolkit
                    self.toolkitStatus = .ok(toolkit.version)
                case .failure(let error):
                    self.toolkitStatus = .failed(Self.reason(for: error))
                }
            }
        }
    }

    func removeToolkit(_ toolkit: Toolkit) {
        try? ToolkitLibrary.remove(toolkit)
        refreshToolkits()
        toolkitStatus = toolkits.isEmpty ? .empty : .ok(selectedToolkit?.version ?? "")
    }

    /// Clears a failed import so the row returns to its drop state (or the library, if any).
    func dismissToolkitError() {
        importingImage = nil
        toolkitStatus = toolkits.isEmpty ? .empty : .ok(selectedToolkit?.version ?? "")
    }

    // MARK: Patching

    func patch() {
        guard let crossOver, let toolkit = selectedToolkit, isReady else { return }
        if mode == .inPlace {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: crossOver.identifier)
            // A never-opened download runs from a hidden translocated copy, whose path differs.
            let name = crossOver.url.lastPathComponent
            if running.contains(where: {
                guard let url = $0.bundleURL else { return false }
                return url.standardizedFileURL == crossOver.url.standardizedFileURL
                    || (url.path.contains("/AppTranslocation/") && url.lastPathComponent == name)
            }) {
                logLines = ["CrossOver is running from \(crossOver.url.path)."]
                phase = .failed(Failure(title: "CrossOver is open", message: "Quit CrossOver before patching it in place, then try again."))
                return
            }
        }
        let applicationsFolder = Self.defaultFolder
        let token = CancellationToken()
        self.token = token
        phase = .running(PatchStep.sequence(for: mode)[0])
        logLines = []
        let log: @Sendable (String) -> Void = { line in
            DispatchQueue.main.async { self.logLines.append(line) }
        }
        let onStep: @Sendable (PatchStep) -> Void = { step in
            DispatchQueue.main.async { if self.isRunning { self.phase = .running(step) } }
        }
        let request = PatchRequest(
            crossOver: crossOver, toolkit: toolkit, mode: mode,
            destination: mode == .inPlace ? crossOver.url : outputURL,
            applicationsFolder: applicationsFolder,
            replaceExisting: false, graphics: graphics, bottles: [])
        Task.detached(priority: .userInitiated) {
            let outcome: Result<URL, Error> = Result {
                try PatchJob(request: request, log: log, onStep: onStep, token: token).run()
            }
            await MainActor.run {
                self.token = nil
                switch outcome {
                case .success(let url):
                    PatchedAppRegistry.remember(url)
                    self.refreshPatchedApps()
                    self.phase = .done(url)
                case .failure(is CancellationError):
                    self.phase = .cancelled
                case .failure(let error):
                    self.logLines.append("Failed: \(error.localizedDescription)")
                    self.phase = .failed(Self.failure(for: error, destination: request.destination))
                }
            }
        }
    }

    func cancel() {
        token?.cancel()
    }

    func reset() {
        phase = .idle
    }

    // MARK: Human-readable errors

    /// One-line reason shown under an input that was rejected.
    static func reason(for error: Error) -> String {
        switch error {
        case PatchError.notCrossOver:
            return "This doesn't appear to be a supported CrossOver installation."
        case PatchError.unsupportedLayout:
            return "This CrossOver version doesn't include D3DMetal, so there's nothing to patch."
        case PatchError.notGPTK:
            return "This disk image doesn't contain the Game Porting Toolkit's evaluation environment."
        case PatchError.command(let command, _) where command.contains("hdiutil"):
            return "The disk image couldn't be mounted. Make sure it isn't damaged or still downloading."
        case PatchError.command:
            return "The toolkit couldn't be copied into the library. Check free space and try again."
        default:
            return error.localizedDescription
        }
    }

    static func failure(for error: Error, destination: URL) -> Failure {
        let title = "Couldn't patch CrossOver"
        let folder = destination.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        let nsError = error as NSError
        let posix = (nsError.userInfo[NSUnderlyingErrorKey] as? NSError).flatMap { $0.domain == NSPOSIXErrorDomain ? $0.code : nil }

        if nsError.domain == NSCocoaErrorDomain {
            switch CocoaError.Code(rawValue: nsError.code) {
            case .fileWriteNoPermission, .fileReadNoPermission:
                return Failure(title: title, message: "You don't have permission to write to \(folder). Choose a different location and try again.")
            case .fileWriteOutOfSpace:
                return Failure(title: title, message: "There isn't enough free space in \(folder).")
            case .fileWriteVolumeReadOnly:
                return Failure(title: title, message: "\(folder) is on a read-only volume. Choose a different location.")
            case .fileNoSuchFile, .fileReadNoSuchFile:
                return Failure(title: title, message: "A file went missing while patching. Make sure CrossOver and the disk image aren't being moved or deleted.")
            default: break
            }
        }
        if posix == Int(EACCES) || posix == Int(EPERM) {
            return Failure(title: title, message: "You don't have permission to write to \(folder). Choose a different location and try again.")
        }
        if posix == Int(ENOSPC) {
            return Failure(title: title, message: "There isn't enough free space in \(folder).")
        }
        switch error {
        case PatchError.notCrossOver, PatchError.unsupportedLayout, PatchError.notGPTK:
            return Failure(title: title, message: reason(for: error))
        case PatchError.command(let command, let result):
            let detail = result.stderr.lowercased()
            if command.contains("hdiutil") {
                return Failure(title: title, message: "The disk image couldn't be mounted. Make sure it isn't damaged or still downloading.")
            }
            if detail.contains("no space") {
                return Failure(title: title, message: "There isn't enough free space in \(folder).")
            }
            if detail.contains("permission denied") || detail.contains("operation not permitted") {
                return Failure(title: title, message: "Some files couldn't be written. Make sure you have permission to write to \(folder) and that CrossOver isn't open.")
            }
            if command.hasPrefix("/bin/cp") || command.hasPrefix("/usr/bin/ditto") {
                return Failure(title: title, message: "CrossOver couldn't be copied. Make sure it isn't being moved or modified, then try again.")
            }
            return Failure(title: title, message: "A step in the patch didn't complete. See Details for what happened.")
        case PatchError.io(let why):
            return Failure(title: title, message: why)
        default:
            return Failure(title: title, message: error.localizedDescription)
        }
    }
}
