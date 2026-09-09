import SwiftUI

/// Receives files dropped on the app icon or opened with the app and routes them to the window,
/// and keeps a quit from cutting a patch off half-way.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            for url in urls { PatchEngine.shared.route(url) }
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Quitting mid-patch would leave CrossOver half-modified. Cancel the job, which puts things
    /// back, and quit once that has finished.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let engine = PatchEngine.shared
        guard engine.isBusy || OperationLock.isHeld else { return .terminateNow }
        engine.cancel()
        Task { @MainActor in
            while engine.isBusy || OperationLock.isHeld { try? await Task.sleep(for: .milliseconds(100)) }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct GPTKPatcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        if CommandLine.arguments.contains("--cli") {
            HeadlessRunner.runAndExit()
        }
        // Shows a window and takes focus even when launched as a bare executable.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        // A single window. Files opened via the Dock or Finder are routed into it.
        Window("GPTK Patcher Tool", id: "main") {
            ContentView()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

/// `GPTKPatcher --cli --quit-bottle <name>` ends everything running in that bottle; `--bottle-status <name>` only lists it.
/// `GPTKPatcher --cli <CrossOver.app> <toolkit.dmg | version> [destination.app] [--in-place] [--replace] [--fps N] [--hud] [--no-copy-env] [--bottle NAME]...`
/// Runs the same job without the window, for scripting and testing.
enum HeadlessRunner {
    private static func quitBottleAndExit(named name: String, dryRun: Bool) -> Never {
        guard let bottle = BottleEnv.listBottles().first(where: { $0.name == name }) else {
            FileHandle.standardError.write(Data("error: no bottle named \(name)\n".utf8)); exit(1)
        }
        guard let running = BottleEnv.runningBottle(for: bottle) else { print("Nothing from the \(name) bottle is running."); exit(0) }
        print("\(dryRun ? "Running in" : "Ending") \(name): server \(running.serverPID.map(String.init) ?? "none"), \(running.clientPIDs.count) program(s)\(running.isStale ? ", stale session" : "") — pids \(running.clientPIDs.map(String.init).joined(separator: " "))")
        if dryRun { exit(0) }
        do { try BottleEnv.quit(running) } catch { FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8)); exit(1) }
        if let left = BottleEnv.runningBottle(for: bottle) { print("Still running: \(left.clientPIDs.count) program(s)"); exit(2) }
        print("Done. Nothing from the \(name) bottle is running.")
        exit(0)
    }

    private static let usage = "usage: GPTKPatcher --cli <CrossOver.app> <toolkit.dmg | version> [destination.app] [--in-place] [--replace] [--fps N] [--hud] [--no-copy-env] [--bottle NAME]...\n       GPTKPatcher --cli --repair <patched.app>\n       GPTKPatcher --cli --quit-bottle <name> | --bottle-status <name>\n"

    private static func fail(_ message: String, status: Int32 = 1) -> Never {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
        exit(status)
    }

    static func runAndExit() -> Never {
        var args = Array(CommandLine.arguments.dropFirst())
        args.removeAll { $0 == "--cli" }
        if args.contains("--help") || args.contains("-h") { print(usage, terminator: ""); exit(0) }
        if args.contains("--repair") {
            guard args.count == 2, args[0] == "--repair", !args[1].hasPrefix("-") else {
                fail("Use --repair with exactly one patched app path.", status: 64)
            }
            do {
                let token = CancellationToken()
                let signals = SignalCancellation(token: token)
                defer { signals.stop() }
                try AppSigning.repair(CrossOverBundle(url: URL(fileURLWithPath: args[1])), token: token, log: { print($0) })
                print("Launch repair complete. Open the app from its current location.")
                exit(0)
            } catch { fail(error.localizedDescription, status: error is CancellationError ? 130 : 1) }
        }
        for flag in ["--quit-bottle", "--bottle-status"] where args.contains(flag) {
            guard args.count == 2, args[0] == flag, !args[1].hasPrefix("-") else {
                fail("Use \(flag) with exactly one bottle name and no patch options.", status: 64)
            }
            quitBottleAndExit(named: args[1], dryRun: flag == "--bottle-status")
        }
        var replace = false
        var inPlace = false
        var hud = false
        var fps: Int? = nil
        var storeInCopy = true
        var bottleNames: [String] = []
        var positional: [String] = []
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--replace": replace = true
            case "--in-place": inPlace = true
            case "--hud": hud = true
            case "--no-copy-env": storeInCopy = false
            case "--fps":
                i += 1
                guard i < args.count, let value = Int(args[i]), value > 0 else { fail("--fps needs a whole number of frames per second", status: 64) }
                fps = value
            case "--bottle":
                i += 1
                guard i < args.count else { fail("--bottle needs a bottle name", status: 64) }
                bottleNames.append(args[i])
            case let flag where flag.hasPrefix("-"): fail("unknown option \(flag)\n\(usage)", status: 64)
            default: positional.append(args[i])
            }
            i += 1
        }
        guard positional.count == (inPlace ? 2 : 3) else {
            FileHandle.standardError.write(Data(usage.utf8))
            exit(64)
        }
        if !inPlace, !positional[2].lowercased().hasSuffix(".app") { fail("the destination must end in .app", status: 64) }
        do {
            let token = CancellationToken()
            let signals = SignalCancellation(token: token)
            defer { signals.stop() }
            let crossOver = try CrossOverBundle(url: URL(fileURLWithPath: positional[0]))
            if !inPlace { try PatchJob.validateDestination(URL(fileURLWithPath: positional[2]), source: crossOver.url) }
            if inPlace {
                let name = crossOver.url.lastPathComponent
                let open = NSRunningApplication.runningApplications(withBundleIdentifier: crossOver.identifier).contains {
                    guard let url = $0.bundleURL else { return false }
                    return url.standardizedFileURL == crossOver.url.standardizedFileURL
                        || (url.path.contains("/AppTranslocation/") && url.lastPathComponent == name)
                }
                if open { fail("\(name) is running. Quit it before patching it in place.") }
            }
            let toolkitArg = positional[1]
            let toolkit: Toolkit
            if toolkitArg.lowercased().hasSuffix(".dmg") {
                toolkit = try ToolkitLibrary.importImage(URL(fileURLWithPath: toolkitArg), token: token) { print($0) }
            } else if let stored = ToolkitLibrary.list().first(where: { $0.version == toolkitArg || $0.displayName == toolkitArg }) {
                toolkit = stored
            } else {
                let known = ToolkitLibrary.list().map(\.version).joined(separator: ", ")
                throw PatchError.io("No toolkit named \(toolkitArg) in the library\(known.isEmpty ? "" : " (have: \(known))"). Pass a .dmg to import one.")
            }
            let bottles = BottleEnv.listBottles().filter { bottleNames.contains($0.name) }
            let missing = Set(bottleNames).subtracting(bottles.map(\.name))
            if !missing.isEmpty { throw PatchError.io("Unknown bottle(s): \(missing.sorted().joined(separator: ", "))") }
            let applications = FileManager.default.isWritableFile(atPath: "/Applications")
                ? URL(fileURLWithPath: "/Applications", isDirectory: true)
                : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
            let request = PatchRequest(
                crossOver: crossOver, toolkit: toolkit, mode: inPlace ? .inPlace : .copy,
                destination: URL(fileURLWithPath: inPlace ? positional[0] : positional[2]),
                applicationsFolder: applications,
                replaceExisting: replace,
                graphics: GraphicsSettings(fpsCap: fps, metalHUD: hud, storeInCopy: storeInCopy),
                bottles: bottles)
            let result = try PatchJob(request: request, log: { print($0) }, token: token).run()
            PatchedAppRegistry.remember(result)
            print(result.path)
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(error is CancellationError ? 130 : 1)
        }
    }
}
