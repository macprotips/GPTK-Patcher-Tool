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
    /// macOS refused the write, which the App Management privacy setting can lift.
    var needsPermission = false
    /// Background services left behind by a bottle, which can be quit from the failure screen.
    var leftovers: [Int32] = []
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

    private var crossOverSelection: CrossOverBundle?
    var crossOver: CrossOverBundle? {
        get { crossOverSelection }
        set {
            guard newValue?.url != crossOverSelection?.url else { return }
            crossOverSelection = newValue
            refreshInstalledVersions()
        }
    }
    var crossOverURL: URL?
    var crossOverStatus: DropStatus = .empty
    var crossOverInstructions: String?

    var toolkits: [Toolkit] = []
    private var toolkitSelection: Toolkit?
    var selectedToolkit: Toolkit? {
        get { toolkitSelection }
        set {
            guard newValue != toolkitSelection else { return }
            toolkitSelection = newValue
            frameCapAfterPatch = newValue.map { NotProton.hasFrameCap(toolkit: $0.lib) } == true
        }
    }
    var importingImage: URL?
    var toolkitStatus: DropStatus = .empty
    var gptkVersion: String? { selectedToolkit?.version }

    var moltenVKBuilds: [MoltenVKBuild] = []
    var selectedMoltenVK: MoltenVKBuild?
    var importingMoltenVK: URL?
    var moltenVKStatus: DropStatus = .empty

    var dxmtBuilds: [DXMTBuild] = []
    var selectedDXMT: DXMTBuild?
    var importingDXMT: URL?
    var dxmtStatus: DropStatus = .empty

    /// Off unless chosen. Nothing about D3DMetal changes when this is nil.

    var patchedApps: [PatchedApp] = []

    private static let modeKey = "patchMode"
    private var chosenMode: PatchMode = PatchMode(rawValue: UserDefaults.standard.string(forKey: PatchEngine.modeKey) ?? "") ?? .copy {
        didSet {
            UserDefaults.standard.set(chosenMode.rawValue, forKey: Self.modeKey)
            refreshAppManagement()
        }
    }

    /// Always in place for NotProton, which never uses a duplicate beside its original.
    var mode: PatchMode {
        get { forNotProton ? .inPlace : chosenMode }
        set { chosenMode = newValue }
    }

    var forNotProton: Bool { destination == .notProton }

    var phase: Phase = .idle
    var logLines: [String] = []

    /// Off by default: a patch that leaves the path alone breaks less. The name is recoverable
    /// from the Patched list and the receipt either way.
    private static let renameKey = "renamePatchedApp"
    var renamePatchedApp: Bool = UserDefaults.standard.bool(forKey: PatchEngine.renameKey) {
        didSet { UserDefaults.standard.set(renamePatchedApp, forKey: Self.renameKey) }
    }

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
    private var importToken: CancellationToken?
    var isCancelling = false

    /// Where the three libraries live: the real ones, except in tests.
    struct LibraryFolders: Sendable {
        var toolkits = ToolkitLibrary.directory
        var dxmt = DXMTLibrary.directory
        var moltenVK = MoltenVKLibrary.directory
    }
    let folders: LibraryFolders

    init(folders: LibraryFolders = LibraryFolders()) {
        self.folders = folders
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
    var isImporting: Bool { importToken != nil }
    var isBusy: Bool { isRunning || isImporting || notProtonUpdating }
    var compatibilityIssue: String? { selectedToolkit?.compatibilityIssue }
    /// Either component is enough to patch; both is the usual case.
    var hasSomethingToInstall: Bool {
        selectedToolkit != nil || selectedDXMT != nil || selectedMoltenVK != nil
    }
    var isReady: Bool { !needsAppManagement && crossOver != nil && hasSomethingToInstall && importingImage == nil && importingDXMT == nil && importingMoltenVK == nil && !isBusy && compatibilityIssue == nil }

    /// The name the copy will get. Never replaces anything: if the name is taken, a counter is added.
    var outputName: String {
        let component = hasSomethingToInstall
            ? PatchJob.components(gptk: gptkVersion, dxmt: selectedDXMT?.version,
                                  moltenVK: selectedMoltenVK.map { $0.version },
                                  games: PatchJob.games(moltenVKBuild: selectedMoltenVK?.name))
            : "GPTK …"
        let base = "\(crossOver?.name ?? "CrossOver") (\(component))"
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

    // MARK: NotProton

    /// What is being patched, which decides the screen the window shows. Nil until the question
    /// has been answered once, or when the answer was NotProton and it has since gone.
    var destination: Destination? = Destination.remembered == .notProton && !NotProton.isInstalled ? nil : Destination.remembered {
        didSet {
            if let destination { Destination.remember(destination) }
            refreshNotProton()
            selectNotProtonsCrossOver()
            // NotProton's CrossOver is patched where it is, which macOS has to allow first.
            if needsAppManagement { Self.openAppManagementSettings() }
        }
    }

    /// macOS will refuse to let this app change the CrossOver it is about to patch in place
    /// until App Management is turned on for it. A duplicate is this app's own, so it is exempt.
    var needsAppManagement = false

    func refreshAppManagement() {
        needsAppManagement = mode == .inPlace && crossOver?.allowsChanges == false
    }

    static func openAppManagementSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles")!)
    }

    /// Whether NotProton is on this Mac. Read at launch and again when the user points at it,
    /// rather than on every redraw.
    var notProtonInstalled = NotProton.isInstalled

    /// Why the app the user pointed at was refused, shown under the question.
    var notProtonLocateError: String?

    /// The CrossOver builds NotProton has cloned. Empty until one has been set up in it.
    var notProtonBuilds: [String] = []

    /// The CrossOver apps NotProton has been set up with. In NotProton mode these are the only
    /// ones that can be patched.
    var notProtonCrossOvers: [URL] = []

    /// NotProton's copy of the selected CrossOver lacks the patch the app now has.
    var notProtonIsBehind = false

    /// Why the last attempt to update NotProton's copy failed.
    var notProtonUpdateError: String?

    /// True while NotProton's copy is being updated.
    var notProtonUpdating = false

    /// Reads NotProton's state for the selected CrossOver. Called when the selection or the
    /// destination changes rather than on every redraw, since it hashes files.
    func refreshNotProton() {
        notProtonBuilds = notProtonInstalled ? NotProton.linkedBuilds() : []
        notProtonCrossOvers = forNotProton ? NotProton.linkedApps() : []
        refreshAppManagement()
        guard forNotProton, let app = crossOver?.url else {
            (notProtonIsBehind, frameCapSupported) = (false, true)
            if forNotProton { refreshSteam() }
            return
        }
        let runners = NotProton.runners(for: app)
        notProtonIsBehind = NotProton.isBehind(app, runners: runners)
        frameCapSupported = NotProton.hasFrameCap(app, runners: runners)
        refreshSteam()
    }

    func locateNotProton(_ app: URL) {
        guard NotProton.locate(app) else {
            notProtonLocateError = "\(app.lastPathComponent) is not NotProton."
            return
        }
        notProtonLocateError = nil
        notProtonInstalled = true
        refreshNotProton()
    }

    private func isNotProtons(_ app: URL) -> Bool {
        let path = app.resolvingSymlinksInPath().path
        return notProtonCrossOvers.contains { $0.path == path }
    }

    /// In NotProton mode the CrossOver is not the user's to pick: it is the one NotProton was
    /// set up with, the first when there are several, and none until one has been set up.
    func selectNotProtonsCrossOver() {
        guard forNotProton, !isBusy else { return }
        if let current = crossOverURL, isNotProtons(current) { return }
        if let first = notProtonCrossOvers.first { setCrossOver(first) } else { clearCrossOver() }
    }

    /// Copies the selected CrossOver's patch into NotProton's copy of it, off the main thread
    /// since it copies files, and under the lock patches take.
    func updateNotProton() {
        guard let crossOver, !isBusy else { return }
        notProtonUpdating = true
        notProtonUpdateError = nil
        let app = crossOver.url, build = crossOver.build
        Task.detached(priority: .userInitiated) {
            let result = Result {
                let lock = try OperationLock()
                defer { lock.unlock() }
                return try NotProton.update(from: app)
            }
            await MainActor.run {
                switch result {
                case .success(let updated):
                    if updated { self.logLines.append("Updated NotProton's copy of build \(build).") }
                case .failure(let error):
                    self.notProtonUpdateError = "NotProton's copy was not updated. \(error.localizedDescription)"
                }
                self.notProtonUpdating = false
                self.refreshNotProton()
            }
        }
    }

    // MARK: Steam launch options

    /// Installed Steam games, and the D3DMetal cap in each one's launch options.
    var steamGames: [Steam.Game] = []
    var steamLaunchOptions: [String: String] = [:]
    var frameCaps: [String: Int] = [:]
    /// False when the D3DMetal that NotProton's games run is too old to have the cap.
    var frameCapSupported = true
    /// The toolkit chosen for the next patch has the cap, so a cap set now works once it is in.
    var frameCapAfterPatch = false

    /// The state of the last launch option change, shown beside the control that made it.
    var launchOptionsBusy = false
    var launchOptionsMessage: String?
    var launchOptionsError: String?

    func refreshSteam() {
        steamGames = Steam.games()
        steamLaunchOptions = Steam.launchOptions(for: steamGames)
        frameCaps = steamLaunchOptions.mapValues(FrameCap.current(in:))
    }

    func setFrameCap(_ fps: Int, for game: Steam.Game) {
        editLaunchOptions([(game.id, { FrameCap.apply(fps, to: $0) })],
                          done: fps > 0 ? "\(game.name) is capped at \(fps) fps on D3DMetal."
                                        : "\(game.name) has no D3DMetal cap.")
    }

    /// True when every one of those games already has what `setUpMoltenVK` adds.
    func moltenVKIsSetUp(for build: MoltenVKLibrary.KnownBuild) -> Bool {
        let games = steamGames(for: build)
        return !games.isEmpty && games.allSatisfy { moltenVKIsSetUp(game: $0, for: build) }
    }

    func moltenVKIsSetUp(game: Steam.Game, for build: MoltenVKLibrary.KnownBuild) -> Bool {
        let argument = build.steamApps.first { $0.id == game.id }?.argument
        let options = steamLaunchOptions[game.id] ?? ""
        return LaunchOptions.settingUpMoltenVK(in: options, settings: build.settings, argument: argument) == options
    }

    /// The installed games a MoltenVK build was made for.
    func steamGames(for build: MoltenVKLibrary.KnownBuild) -> [Steam.Game] {
        steamGames.filter { game in build.steamApps.contains { $0.id == game.id } }
    }

    /// Gives those games the launch options they need to use the build under NotProton.
    func setUpMoltenVK(for build: MoltenVKLibrary.KnownBuild, only game: Steam.Game? = nil) {
        let games = game.map { [$0] } ?? steamGames(for: build)
        let edits = build.steamApps.filter { app in games.contains { $0.id == app.id } }.map { app in
            (app.id, { LaunchOptions.settingUpMoltenVK(in: $0, settings: build.settings, argument: app.argument) })
        }
        editLaunchOptions(edits, done: nil)
    }

    /// Rewrites games' launch options, closing Steam first when it is open and reopening it
    /// afterwards.
    private func editLaunchOptions(_ edits: [Steam.Edit], done: String?) {
        launchOptionsBusy = true
        launchOptionsError = nil
        launchOptionsMessage = nil
        Task { @MainActor in
            defer { launchOptionsBusy = false; refreshSteam() }
            let wasRunning = !Steam.running.isEmpty
            do {
                // Checked first, so Steam is not closed for an edit that cannot be made.
                try Steam.validate(edits)
                if wasRunning {
                    launchOptionsMessage = "Waiting for Steam to quit…"
                    Steam.running.forEach { $0.terminate() }
                    let deadline = Date().addingTimeInterval(30)
                    while !Steam.running.isEmpty, Date() < deadline { try? await Task.sleep(for: .milliseconds(500)) }
                }
                try Steam.editLaunchOptions(edits)
                launchOptionsMessage = done
            } catch {
                launchOptionsMessage = nil
                launchOptionsError = error.localizedDescription
            }
            if wasRunning, let steam = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Steam.bundleIdentifier) {
                NSWorkspace.shared.open(steam)
            }
        }
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

    /// The inputs a file can go to.
    enum Input: Sendable { case crossOver, toolkit, dxmt, moltenVK }

    /// Which input a file belongs to. A tar archive can be a DXMT release or a MoltenVK one: the
    /// tile it was dropped on decides, then its name, and DXMT otherwise, since DXMT ships as one.
    nonisolated static func input(for url: URL, preferring preferred: Input? = nil) -> Input? {
        switch url.pathExtension.lowercased() {
        case "app": return .crossOver
        case "dmg": return .toolkit
        default: break
        }
        let dxmt = DXMTLibrary.looksLikeArchive(url), moltenVK = MoltenVKLibrary.looksLikeBuild(url)
        if dxmt, moltenVK {
            if preferred == .dxmt || preferred == .moltenVK { return preferred }
            return url.lastPathComponent.localizedCaseInsensitiveContains("moltenvk") ? .moltenVK : .dxmt
        }
        if dxmt { return .dxmt }
        if moltenVK { return .moltenVK }
        return nil
    }

    /// Sends any dropped or chosen file to the right slot, whichever tile it landed on. False when
    /// the file is not one this app takes, or nothing can be added right now.
    @discardableResult
    func route(_ url: URL, preferring preferred: Input? = nil) -> Bool {
        guard !isRunning, !isCancelling else { return false }
        switch Self.input(for: url, preferring: preferred) {
        case .crossOver:
            if forNotProton { return false }
            phase = .idle
            setCrossOver(url)
            return true
        case .toolkit:
            guard !isBusy else { return false }
            importToolkit(from: url)
            return true
        case .dxmt:
            guard !isBusy else { return false }
            importDXMT(from: url)
            return true
        case .moltenVK:
            guard !isBusy else { return false }
            importMoltenVK(from: url)
            return true
        case nil:
            return false
        }
    }

    func setCrossOver(_ url: URL) {
        guard !isRunning else { return }
        // A duplicate or a CrossOver NotProton has not been given would change nothing there.
        if forNotProton, !isNotProtons(url) { return }
        defer {
            refreshInstalledVersions()
            refreshNotProton()
        }
        crossOverURL = url
        crossOverInstructions = nil
        if case .cancelled = phase { phase = .idle }
        do {
            let bundle = try CrossOverBundle(url: url)
            _ = try bundle.gptkDirectory()
            try bundle.requireFirstLaunchApproval()
            crossOver = bundle
            var lines = [bundle.displayVersion]
            if let stock = bundle.installedD3DMetalVersion { lines.append("D3DMetal \(stock)") }
            if bundle.hasARM64Wine { lines.append("GPTK applies to Intel bottles only") }
            crossOverStatus = .ok(lines.joined(separator: "\n"))
        } catch {
            crossOver = nil
            crossOverStatus = .failed(Self.reason(for: error))
            if case PatchError.firstLaunchRequired = error {
                crossOverInstructions = error.localizedDescription + " Drag the app in again or click the CrossOver tile to add it."
            }
        }
    }

    func clearCrossOver() {
        guard !isRunning else { return }
        crossOver = nil
        crossOverURL = nil
        crossOverStatus = .empty
        crossOverInstructions = nil
        refreshNotProton()
    }

    func refreshPatchedApps() {
        patchedApps = PatchedAppRegistry.load()
    }

    // MARK: Toolkit library

    func refreshToolkits() {
        toolkits = ToolkitLibrary.list(directory: folders.toolkits)
        if let selected = selectedToolkit, let match = toolkits.first(where: { $0.version == selected.version }) {
            selectedToolkit = match
        } else if !leavingToolkitAlone {
            // Nothing chosen yet: start on the newest toolkit, since replacing it is the usual case.
            // "Unchanged" is a decision, though, and a refresh must not quietly undo it.
            selectedToolkit = toolkits.first
        }
        if toolkits.isEmpty, case .ok = toolkitStatus { toolkitStatus = .empty }
    }

    /// Set when the toolkit is deliberately left alone, so a refresh does not choose one again.
    private var leavingToolkitAlone = false

    /// Leaves the toolkit in the library but takes it out of this patch, so only the other
    /// components are replaced.
    func clearToolkit() {
        leavingToolkitAlone = true
        selectedToolkit = nil
        toolkitStatus = .empty
    }

    func selectToolkit(_ toolkit: Toolkit) {
        guard !isBusy else { return }
        leavingToolkitAlone = false
        selectedToolkit = toolkit
        toolkitStatus = .ok(toolkit.version)
    }

    /// What is being added to a library right now, for the line under the tiles.
    private(set) var importingComponent: String?

    /// Runs one library import off the main thread. However it ends, the import's own state is
    /// cleared before `finished` runs, so a cancelled import never leaves the window refusing
    /// files or busy for good.
    private func runImport<Build: Sendable>(_ component: String,
                                            _ work: @escaping @Sendable (CancellationToken) throws -> Build,
                                            finished: @escaping @MainActor @Sendable (Result<Build, Error>) -> Void) {
        let token = CancellationToken()
        importToken = token
        importingComponent = component
        isCancelling = false
        if case .cancelled = phase { phase = .idle }
        Task.detached(priority: .userInitiated) {
            let result = Result { try work(token) }
            await MainActor.run {
                if self.importToken === token {
                    self.importToken = nil
                    self.importingComponent = nil
                    self.isCancelling = false
                }
                finished(result)
            }
        }
    }

    /// Copies the image's payload into the library, then selects it.
    func importToolkit(from url: URL) {
        guard !isBusy else { return }
        importingImage = url
        leavingToolkitAlone = false
        toolkitStatus = .checking("Adding to the library…")
        let directory = folders.toolkits
        runImport("the toolkit", { token in
            try ToolkitLibrary.importImage(url, directory: directory, token: token) { _ in }
        }) { result in
            switch result {
            case .success(let toolkit):
                self.importingImage = nil
                self.refreshToolkits()
                self.selectedToolkit = self.toolkits.first { $0.version == toolkit.version } ?? toolkit
                self.toolkitStatus = .ok(toolkit.version)
            case .failure(is CancellationError):
                self.importingImage = nil
                self.toolkitStatus = self.selectedToolkit.map { .ok($0.version) } ?? .empty
            case .failure(let error):
                self.toolkitStatus = .failed(Self.reason(for: error))
            }
        }
    }

    func removeToolkit(_ toolkit: Toolkit) {
        guard !isBusy else { return }
        do {
            try ToolkitLibrary.remove(toolkit, directory: folders.toolkits)
            refreshToolkits()
            toolkitStatus = toolkits.isEmpty ? .empty : .ok(selectedToolkit?.version ?? "")
        } catch {
            logLines = [error.localizedDescription]
            phase = .failed(Failure(title: "Couldn't remove the toolkit", message: error.localizedDescription))
        }
    }

    /// Clears a failed import so the row returns to its drop state (or the library, if any).
    func dismissToolkitError() {
        guard !isBusy else { return }
        importingImage = nil
        toolkitStatus = toolkits.isEmpty ? .empty : .ok(selectedToolkit?.version ?? "")
    }

    /// The D3DMetal the selected CrossOver already has, read when it was chosen.
    private(set) var installedD3DMetal: String?
    /// The DXMT in the selected CrossOver, for the tile's label.
    private(set) var installedDXMT: String?

    /// Read when the selection is set, since an in-place patch changes them without changing it.
    private func refreshInstalledVersions() {
        installedD3DMetal = crossOver?.installedD3DMetalVersion
        installedDXMT = crossOver?.installedDXMTVersion
    }

    /// Installing a toolkit older than the one already in the app. Legitimate, but never silent.
    var downgradeNotice: String? {
        guard let installed = installedD3DMetal, let chosen = selectedToolkit?.version,
              D3DMetalVersion.isOlder(chosen, than: installed) else { return nil }
        return "This CrossOver already has D3DMetal \(installed). The toolkit you chose is \(chosen), which is older, and patching replaces the newer one. Its original is kept and can be put back."
    }

    /// This app has patched the selected CrossOver before, so patching it again in place is
    /// how it is updated.
    var crossOverIsAlreadyPatched: Bool { crossOverSelection?.hasPatchBackup == true }

    // MARK: DXMT library

    func refreshDXMT() {
        dxmtBuilds = DXMTLibrary.list(directory: folders.dxmt)
        if let selected = selectedDXMT, let match = dxmtBuilds.first(where: { $0.version == selected.version }) {
            selectedDXMT = match
        } else if selectedDXMT != nil {
            selectedDXMT = dxmtBuilds.first
        }
        if dxmtBuilds.isEmpty { dxmtStatus = .empty }
    }

    func selectDXMT(_ build: DXMTBuild) {
        selectedDXMT = build
        dxmtStatus = .ok(build.version)
    }

    /// Unpacks the archive into the library, then selects it.
    func importDXMT(from url: URL) {
        guard !isBusy else { return }
        importingDXMT = url
        dxmtStatus = .checking("Adding to the library…")
        let directory = folders.dxmt
        runImport("DXMT", { token in
            try DXMTLibrary.importArchive(url, directory: directory, token: token) { _ in }
        }) { result in
            self.importingDXMT = nil
            switch result {
            case .success(let build):
                self.dxmtBuilds = DXMTLibrary.list(directory: directory)
                self.selectedDXMT = self.dxmtBuilds.first { $0.version == build.version } ?? build
                self.dxmtStatus = .ok(build.version)
            case .failure(is CancellationError):
                // Cancelled on purpose: back to what was chosen before, not an error.
                self.dxmtStatus = self.selectedDXMT.map { .ok($0.version) } ?? .empty
            case .failure(let error):
                self.dxmtStatus = .failed(Self.reason(for: error))
            }
        }
    }

    /// Removing the chosen build leaves DXMT unchanged rather than quietly choosing another one:
    /// the next patch would otherwise install something nobody picked.
    func removeDXMT(_ build: DXMTBuild) {
        guard !isBusy else { return }
        try? DXMTLibrary.remove(build, directory: folders.dxmt)
        dxmtBuilds = DXMTLibrary.list(directory: folders.dxmt)
        if selectedDXMT?.version == build.version { selectedDXMT = nil }
        dxmtStatus = selectedDXMT.map { .ok($0.version) } ?? .empty
    }

    /// Leaves the build in the library but takes it out of this patch. Not while one is being
    /// imported, whose result still has to land: Cancel Import stops that.
    func clearDXMT() {
        guard importingDXMT == nil else { return }
        selectedDXMT = nil
        dxmtStatus = .empty
    }

    // MARK: MoltenVK library

    func refreshMoltenVK() {
        moltenVKBuilds = MoltenVKLibrary.all(directory: folders.moltenVK)
        if let selected = selectedMoltenVK, let match = moltenVKBuilds.first(where: { $0.name == selected.name }) {
            selectedMoltenVK = match
        } else if selectedMoltenVK != nil {
            selectedMoltenVK = moltenVKBuilds.first
        }
        if moltenVKBuilds.isEmpty { moltenVKStatus = .empty }
    }

    func selectMoltenVK(_ build: MoltenVKBuild) {
        selectedMoltenVK = build
        moltenVKStatus = .ok(build.name)
    }

    func importMoltenVK(from url: URL) {
        guard !isBusy else { return }
        importingMoltenVK = url
        moltenVKStatus = .checking("Adding to the library…")
        let directory = folders.moltenVK
        runImport("MoltenVK", { token in
            try MoltenVKLibrary.importBuild(url, directory: directory, token: token) { _ in }
        }) { result in
            self.importingMoltenVK = nil
            switch result {
            case .success(let build):
                self.moltenVKBuilds = MoltenVKLibrary.all(directory: directory)
                self.selectedMoltenVK = self.moltenVKBuilds.first { $0.name == build.name } ?? build
                self.moltenVKStatus = .ok(build.name)
            case .failure(is CancellationError):
                self.moltenVKStatus = self.selectedMoltenVK.map { .ok($0.name) } ?? .empty
            case .failure(let error):
                self.moltenVKStatus = .failed(Self.reason(for: error))
            }
        }
    }

    /// As with DXMT: removing the chosen build leaves MoltenVK unchanged.
    func removeMoltenVK(_ build: MoltenVKBuild) {
        guard !isBusy else { return }
        try? MoltenVKLibrary.remove(build, directory: folders.moltenVK)
        moltenVKBuilds = MoltenVKLibrary.all(directory: folders.moltenVK)
        if selectedMoltenVK?.name == build.name { selectedMoltenVK = nil }
        moltenVKStatus = selectedMoltenVK.map { .ok($0.name) } ?? .empty
    }

    /// Leaves the build in the library but takes it out of this patch. As with DXMT, not while
    /// one is being imported.
    func clearMoltenVK() {
        guard importingMoltenVK == nil else { return }
        selectedMoltenVK = nil
        moltenVKStatus = .empty
    }

    // MARK: Patching

    /// Quits services a bottle left behind, then patches again. Each one is checked to still be
    /// one of those services first, since a process id can be reused.
    func quitLeftovers(_ pids: [Int32]) {
        guard let crossOver else { return }
        let app = crossOver.url
        Task.detached(priority: .userInitiated) {
            let current = Set((BottleEnv.processesUsingApp(app) ?? []).map(\.pid))
            let targets = pids.filter(current.contains)
            targets.forEach { kill($0, SIGTERM) }
            for _ in 0..<20 where targets.contains(where: { kill($0, 0) == 0 }) {
                try? await Task.sleep(for: .milliseconds(250))
            }
            targets.filter { kill($0, 0) == 0 }.forEach { kill($0, SIGKILL) }
            await MainActor.run {
                self.reset()
                self.patch()
            }
        }
    }

    func patch() {
        guard let crossOver, isReady else { return }
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
        isCancelling = false
        phase = .running(PatchStep.sequence(for: mode)[0])
        logLines = []
        let log: @Sendable (String) -> Void = { line in
            DispatchQueue.main.async { self.logLines.append(line) }
        }
        let onStep: @Sendable (PatchStep) -> Void = { step in
            DispatchQueue.main.async { if self.isRunning { self.phase = .running(step) } }
        }
        let request = PatchRequest(
            crossOver: crossOver, toolkit: selectedToolkit, dxmt: selectedDXMT, moltenVK: selectedMoltenVK,
            mode: mode, renameInPlace: forNotProton ? false : renamePatchedApp,
            moveToApplications: !forNotProton,
            destination: mode == .inPlace ? crossOver.url : outputURL,
            applicationsFolder: applicationsFolder,
            replaceExisting: false, graphics: graphics, bottles: [])
        Task.detached(priority: .userInitiated) {
            let outcome: Result<URL, Error> = Result {
                try PatchJob(request: request, log: log, onStep: onStep, token: token).run()
            }
            await MainActor.run {
                self.token = nil
                self.isCancelling = false
                switch outcome {
                case .success(let url):
                    PatchedAppRegistry.remember(url)
                    self.refreshPatchedApps()
                    self.phase = .done(url)
                    if request.mode == .inPlace { self.setCrossOver(url) }
                    // Patch NotProton means its copy as well.
                    if self.notProtonIsBehind { self.updateNotProton() }
                    // And the launch options a MoltenVK build's games need, when that does not
                    // mean closing Steam. With Steam open the finish screen asks first.
                    if self.forNotProton, let build = request.moltenVK?.catalogue,
                       !self.steamGames(for: build).isEmpty, !self.moltenVKIsSetUp(for: build),
                       Steam.running.isEmpty {
                        self.setUpMoltenVK(for: build)
                    }
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
        guard isBusy else { return }
        isCancelling = true
        token?.cancel()
        importToken?.cancel()
    }

    func reset() {
        guard !isBusy else { return }
        phase = .idle
        launchOptionsMessage = nil
        launchOptionsError = nil
        refreshToolkits()
        refreshPatchedApps()
    }

    // MARK: Human-readable errors

    /// One-line reason shown under an input that was rejected.
    static func reason(for error: Error) -> String {
        switch error {
        case PatchError.firstLaunchRequired:
            return "Open CrossOver once first."
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

        if case PatchError.leftoverServices(_, let pids) = error {
            return Failure(title: title, message: error.localizedDescription, leftovers: pids)
        }
        if nsError.domain == NSCocoaErrorDomain {
            switch CocoaError.Code(rawValue: nsError.code) {
            case .fileWriteNoPermission, .fileReadNoPermission:
                return Failure(title: title, message: "macOS did not let this app change files in \(folder). Allow GPTK Patcher Tool under App Management in Privacy & Security, then try again.", needsPermission: true)
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
            return Failure(title: title, message: "macOS did not let this app change files in \(folder). Allow GPTK Patcher Tool under App Management in Privacy & Security, then try again.", needsPermission: true)
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
                return Failure(title: title, message: "Some files couldn't be written. Allow GPTK Patcher Tool under App Management in Privacy & Security, make sure CrossOver isn't open, then try again.", needsPermission: true)
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
