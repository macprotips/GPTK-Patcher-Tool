import XCTest
import SwiftUI
@testable import GPTKPatcher

final class StabilityTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("GPTKPatcher-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws { try fm.removeItem(at: root) }

    private func write(_ text: String, _ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func plist(_ values: [String: Any], at url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0).write(to: url)
    }

    private func payload(at lib: URL, version: String) throws {
        for name in GPTKSource.requiredFiles where name != "external/D3DMetal.framework/D3DMetal" {
            let file = lib.appendingPathComponent(name)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("payload-\(version)-\(name)".utf8).write(to: file)
        }
        let framework = lib.appendingPathComponent("external/D3DMetal.framework")
        try fm.createSymbolicLink(atPath: framework.appendingPathComponent("Versions/Current").path, withDestinationPath: "A")
        try fm.createSymbolicLink(atPath: framework.appendingPathComponent("D3DMetal").path, withDestinationPath: "Versions/Current/D3DMetal")
        try plist(["CFBundleShortVersionString": version, "LSMinimumSystemVersion": "14.0"],
                  at: framework.appendingPathComponent("Versions/A/Resources/Info.plist"))
        let alias = lib.appendingPathComponent("wine/x86_64-windows/nvngx-on-metalfx.dll")
        try Data("DLSS shim".utf8).write(to: alias)
    }

    private func fixture() throws -> (CrossOverBundle, Toolkit) {
        let app = root.appendingPathComponent("CrossOver.app")
        try plist(["CFBundleIdentifier": "com.codeweavers.CrossOver", "CFBundleName": "CrossOver",
                   "CFBundleExecutable": "Stub", "CFBundlePackageType": "APPL",
                   "CFBundleShortVersionString": "26.2", "CFBundleVersion": "26.2"],
                  at: app.appendingPathComponent("Contents/Info.plist"))
        try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: app.appendingPathComponent("Contents/MacOS/Stub"))
        try payload(at: app.appendingPathComponent("Contents/SharedSupport/CrossOver/lib64/apple_gptk"), version: "3.0")
        _ = try write("[EnvironmentVariables]\n\"UNRELATED\" = \"keep\"\n", "CrossOver.app/Contents/SharedSupport/CrossOver/etc/CrossOver.conf")
        try Shell.check("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        let lib = root.appendingPathComponent("toolkit")
        try payload(at: lib, version: "4.0b2")
        return (try CrossOverBundle(url: app), Toolkit(version: "4.0b2", lib: lib, importedAt: Date(), minimumOS: "14.0", sourceName: "test.dmg"))
    }

    private func request(_ app: CrossOverBundle, _ kit: Toolkit, mode: PatchMode = .copy,
                         bottles: [BottleEnv.Bottle] = []) -> PatchRequest {
        PatchRequest(crossOver: app, toolkit: kit, mode: mode, destination: root.appendingPathComponent("Patched.app"),
                     applicationsFolder: root.appendingPathComponent("Applications"), replaceExisting: false,
                     graphics: GraphicsSettings(fpsCap: 120, metalHUD: true), bottles: bottles)
    }

    private func assertSigned(_ url: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let result = try Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", url.path])
        XCTAssertEqual(result.status, 0, result.stderr, file: file, line: line)
    }

    private func quarantine(_ url: URL, value: String = "0081;1234;Test;") throws {
        let data = Data(value.utf8)
        let result = data.withUnsafeBytes { setxattr(url.path, "com.apple.quarantine", $0.baseAddress, data.count, 0, XATTR_NOFOLLOW) }
        if result != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
    }

    func testDuplicateProducesSignedAppAndLeavesOriginalIntact() throws {
        let (app, kit) = try fixture()
        let original = try Data(contentsOf: app.globalConfig)
        try quarantine(app.url, value: "01e3;1234;Test;")
        let result = try PatchJob(request: request(app, kit), log: { _ in }).run()
        try assertSigned(result)
        try assertSigned(app.url)
        XCTAssertEqual(try Data(contentsOf: app.globalConfig), original)
        let patched = try CrossOverBundle(url: result)
        XCTAssertTrue(patched.hasPatchBackup)
        XCTAssertEqual(D3DMetalInfo.read(inLib: try patched.gptkDirectory()).version, "4.0b2")
        XCTAssertEqual(D3DMetalInfo.read(inLib: try patched.gptkDirectory().appendingPathExtension("stock")).version, "3.0")
        XCTAssertEqual(CXConfig.value(of: "D3DM_MAX_FPS", in: patched.globalConfig), "120")
        XCTAssertEqual(getxattr(result.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW), -1)
        XCTAssertGreaterThan(getxattr(app.url.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW), 0)
        let lib = try patched.gptkDirectory()
        XCTAssertEqual(try Data(contentsOf: lib.appendingPathComponent("wine/x86_64-windows/nvngx.dll")), Data("DLSS shim".utf8))
        let data = try Data(contentsOf: result.appendingPathComponent(PatchedAppRegistry.receiptPath))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let relative = try XCTUnwrap(json["gptkDirectory"] as? String)
        XCTAssertTrue(relative.hasPrefix("Contents/"))
        XCTAssertTrue(fm.fileExists(atPath: result.appendingPathComponent(relative).path))
    }

    func testFirstLaunchCheckUsesApprovalRatherThanMissingLaunchHistory() throws {
        let (app, _) = try fixture()
        // Missing or unreadable history does not prove a local/older copy was never opened.
        XCTAssertNoThrow(try app.requireFirstLaunchApproval())
        try quarantine(app.url, value: "0083;1234;Safari;")
        XCTAssertThrowsError(try app.requireFirstLaunchApproval()) { error in
            guard case PatchError.firstLaunchRequired = error else { return XCTFail("Unexpected error: \(error)") }
        }
        try quarantine(app.url, value: "01e3;1234;Safari;")
        XCTAssertNoThrow(try app.requireFirstLaunchApproval())
        try quarantine(app.url, value: "invalid-record")
        XCTAssertNoThrow(try app.requireFirstLaunchApproval())
    }

    @MainActor
    func testReaddingCrossOverAfterFirstLaunchClearsTheRejection() throws {
        let (app, kit) = try fixture()
        let engine = PatchEngine()
        engine.selectedToolkit = kit
        engine.setCrossOver(app.url)
        XCTAssertTrue(engine.isReady)

        try quarantine(app.url, value: "0083;1234;Safari;")
        engine.phase = .done(app.url)
        XCTAssertTrue(engine.route(app.url))
        XCTAssertEqual(engine.phase, .idle)
        XCTAssertNil(engine.crossOver)
        XCTAssertFalse(engine.isReady)
        XCTAssertEqual(engine.crossOverStatus, .failed("Open CrossOver once first."))
        XCTAssertTrue(try XCTUnwrap(engine.crossOverInstructions).contains("Drag the app in again"))

        // Simulate macOS recording approval, then re-add the same file through the shared route.
        try quarantine(app.url, value: "01e3;1234;Safari;")
        XCTAssertTrue(engine.route(app.url))
        XCTAssertTrue(engine.isReady)
        XCTAssertNil(engine.crossOverInstructions)

        try quarantine(app.url, value: "0083;1234;Safari;")
        engine.setCrossOver(app.url)
        engine.clearCrossOver()
        XCTAssertNil(engine.crossOverInstructions)
        XCTAssertEqual(engine.crossOverStatus, .empty)
    }

    func testPatchRechecksFirstLaunchBeforeCreatingOrChangingFiles() throws {
        let (app, kit) = try fixture()
        let job = request(app, kit)
        let before = try Data(contentsOf: app.globalConfig)
        // Approval changes after selection must still be caught by the shared patch job.
        try quarantine(app.url, value: "0083;1234;Safari;")
        XCTAssertThrowsError(try PatchJob(request: job, log: { _ in }).run()) { error in
            guard case PatchError.firstLaunchRequired = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertFalse(fm.fileExists(atPath: job.destination.path))
        XCTAssertEqual(try Data(contentsOf: app.globalConfig), before)
        XCTAssertFalse(fm.fileExists(atPath: try app.gptkDirectory().appendingPathExtension("stock").path))
        try assertSigned(app.url)
    }

    func testRepatchPreservesStockAndRelocatableReceipt() throws {
        let (app, kit) = try fixture()
        let first = try PatchJob(request: request(app, kit), log: { _ in }).run()
        let result = try PatchJob(request: request(CrossOverBundle(url: first), kit, mode: .inPlace), log: { _ in }).run()
        try assertSigned(result)
        XCTAssertFalse(fm.fileExists(atPath: first.path))
        XCTAssertEqual(D3DMetalInfo.read(inLib: try CrossOverBundle(url: result).gptkDirectory().appendingPathExtension("stock")).version, "3.0")
        XCTAssertFalse(fm.fileExists(atPath: result.appendingPathComponent("Contents/SharedSupport/CrossOver/lib64/.apple_gptk.previous").path))
    }

    func testCancellationAfterToolkitSwapRestoresOriginalSignature() throws {
        let (app, kit) = try fixture()
        let token = CancellationToken()
        XCTAssertThrowsError(try PatchJob(request: request(app, kit, mode: .inPlace), log: { _ in },
            onStep: { if $0 == .finalizing { token.cancel() } }, token: token).run()) { XCTAssertTrue($0 is CancellationError) }
        try assertSigned(app.url)
        XCTAssertEqual(app.installedD3DMetalVersion, "3.0")
        XCTAssertFalse(fm.fileExists(atPath: app.url.appendingPathComponent(PatchedAppRegistry.receiptPath).path))
    }

    func testCancellationRestoresExternalBottleEvenWhenDuplicateIsDeleted() throws {
        let (app, kit) = try fixture()
        let conf = try write("[EnvironmentVariables]\n\"D3DM_MAX_FPS\" = \"42\"\n", "bottle/cxbottle.conf")
        let before = try Data(contentsOf: conf)
        let token = CancellationToken()
        let job = request(app, kit, bottles: [BottleEnv.Bottle(name: "Fixture", conf: conf)])
        XCTAssertThrowsError(try PatchJob(request: job, log: { _ in },
            onStep: { if $0 == .signing { token.cancel() } }, token: token).run())
        XCTAssertEqual(try Data(contentsOf: conf), before)
        XCTAssertFalse(fm.fileExists(atPath: conf.appendingPathExtension("gptkpatcher.bak").path))
        XCTAssertFalse(fm.fileExists(atPath: job.destination.path))
        try assertSigned(app.url)
    }

    func testMissingConfigRollsBackAnInPlacePatch() throws {
        let (app, kit) = try fixture()
        try fm.removeItem(at: app.globalConfig)
        try Shell.check("/usr/bin/codesign", ["--force", "--sign", "-", app.url.path])
        XCTAssertThrowsError(try PatchJob(request: request(app, kit, mode: .inPlace), log: { _ in }).run())
        XCTAssertEqual(app.installedD3DMetalVersion, "3.0")
        try assertSigned(app.url)
    }

    func testDestinationsCannotOverlapSourceIncludingSymlinks() throws {
        let source = root.appendingPathComponent("Outer.app/CrossOver.app")
        for destination in [source, source.appendingPathComponent("Nested.app"), source.deletingLastPathComponent()] {
            XCTAssertThrowsError(try PatchJob.validateDestination(destination, source: source))
        }
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("Alias.app")
        try fm.createSymbolicLink(at: alias, withDestinationURL: source)
        XCTAssertThrowsError(try PatchJob.validateDestination(alias, source: source))
        XCTAssertNoThrow(try PatchJob.validateDestination(root.appendingPathComponent("New.app"), source: source))
    }

    func testPartialPayloadRejectedBeforeCreatingDestination() throws {
        let (app, kit) = try fixture()
        try fm.removeItem(at: kit.lib.appendingPathComponent("wine/x86_64-windows/d3d12.dll"))
        let job = request(app, kit)
        XCTAssertThrowsError(try PatchJob(request: job, log: { _ in }).run())
        XCTAssertFalse(fm.fileExists(atPath: job.destination.path))
        try assertSigned(app.url)
    }

    func testUntrackedModificationOfSourceIsRejected() throws {
        let (app, kit) = try fixture()
        try Data("modified".utf8).write(to: app.globalConfig)
        XCTAssertThrowsError(try PatchJob(request: request(app, kit), log: { _ in }).run())
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("Patched.app").path))
    }

    func testPayloadAllowsFrameworkLinksButRejectsEscapingLinks() throws {
        let (_, kit) = try fixture()
        try GPTKSource.validateLib(kit.lib)
        let link = kit.lib.appendingPathComponent("external/D3DMetal.framework/D3DMetal")
        try fm.removeItem(at: link)
        let outside = try write("outside", "outside")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try GPTKSource.validateLib(kit.lib))
    }

    func testUnsafeVersionMetadataCannotBecomeAPath() {
        for version in ["", ".", "..", "../../other", "4/../../other", "4\n"] { XCTAssertFalse(FileSafety.isSafeComponent(version)) }
        XCTAssertTrue(FileSafety.isSafeComponent("4.0b2"))
    }

    func testRemovalCannotUseASiblingLibraryPrefix() throws {
        let external = try write("keep", "Toolkits-other/4.0/file")
        let kit = Toolkit(version: "4.0", lib: external.deletingLastPathComponent(), importedAt: Date(), minimumOS: nil, sourceName: nil)
        XCTAssertThrowsError(try ToolkitLibrary.remove(kit, directory: root.appendingPathComponent("Toolkits")))
        XCTAssertTrue(fm.fileExists(atPath: external.path))
    }

    func testMinimumOSComparisonIncludesMinorAndPatchVersions() {
        let running = OperatingSystemVersion(majorVersion: 26, minorVersion: 2, patchVersion: 0)
        XCTAssertNil(Toolkit.compatibilityIssue(version: "4.0b2", minimumOS: "14.0", running: running))
        XCTAssertNil(Toolkit.compatibilityIssue(version: "4.0b2", minimumOS: "26.2", running: running))
        XCTAssertNotNil(Toolkit.compatibilityIssue(version: "4.0b2", minimumOS: "26.2.1", running: running))
        XCTAssertNotNil(Toolkit.compatibilityIssue(version: "4.0b2", minimumOS: "27.0", running: running))
        XCTAssertNotNil(Toolkit.compatibilityIssue(version: "4.0b2", minimumOS: "26..2", running: running))
    }

    func testVersionAndMinimumOSCanComeFromDifferentPlists() throws {
        let lib = root.appendingPathComponent("lib")
        let resources = lib.appendingPathComponent("external/D3DMetal.framework/Versions/A/Resources")
        try plist(["CFBundleShortVersionString": "4.0b2"], at: resources.appendingPathComponent("Info.plist"))
        try plist(["LSMinimumSystemVersion": "14.0"], at: resources.appendingPathComponent("version.plist"))
        XCTAssertEqual(D3DMetalInfo.read(inLib: lib).minimumOS, "14.0")
    }

    func testRepeatedConfigSectionsCannotShadowAnEditOrRemoval() throws {
        let conf = try write("[EnvironmentVariables]\n\"MTL_HUD_ENABLED\" = \"0\"\n[Other]\n\"Keep\" = \"yes\"\n[environmentvariables] ; comment\n\"mtl_hud_enabled\" = \"0\"\n", "repeat.conf")
        try CXConfig.set("MTL_HUD_ENABLED", to: "1", in: conf)
        XCTAssertEqual(CXConfig.value(of: "MTL_HUD_ENABLED", in: conf), "1")
        try CXConfig.set("MTL_HUD_ENABLED", to: nil, in: conf)
        XCTAssertNil(CXConfig.value(of: "MTL_HUD_ENABLED", in: conf))
        XCTAssertTrue(try String(contentsOf: conf).contains("\"Keep\" = \"yes\""))
    }

    func testConfigPreservesCRLFAndTheFirstBackup() throws {
        let text = "[EnvironmentVariables]\r\n\"MTL_HUD_ENABLED\" = \"0\"\r\n"
        let conf = try write(text, "line-endings.conf")
        try CXConfig.set("MTL_HUD_ENABLED", to: "1", in: conf)
        XCTAssertEqual(try String(contentsOf: conf.appendingPathExtension("gptkpatcher.bak")), text)
        XCTAssertTrue(try String(contentsOf: conf).contains("\r\n"))
        XCTAssertFalse(try CXConfig.set("MTL_HUD_ENABLED", to: "1", in: conf))
    }

    func testInvalidAssignmentDoesNotPartiallyWriteEarlierKeys() throws {
        let conf = try write("[EnvironmentVariables]\n", "invalid.conf")
        let before = try Data(contentsOf: conf)
        XCTAssertThrowsError(try CXConfig.apply([("MTL_HUD_ENABLED", "1"), ("D3DM_MAX_FPS", "60\nBAD")], to: conf))
        XCTAssertEqual(try Data(contentsOf: conf), before)
    }

    func testOffOverridesInheritedOnAndOnlyChangesSelectedSettings() throws {
        let (app, _) = try fixture()
        try CXConfig.apply([("MTL_HUD_ENABLED", "1"), ("D3DM_MAX_FPS", "120")], to: app.globalConfig)
        let bottle = try write("[EnvironmentVariables]\n\"D3DM_MTL4\" = \"1\"\n", "bottle.conf")
        let saved = GraphicsOptions.load(from: bottle, inheriting: app.globalConfig)
        XCTAssertTrue(saved.hud)
        XCTAssertTrue(saved.fpsEnabled)
        var off = saved
        off.hud = false
        off.fpsEnabled = false
        try AppSettings.apply(off.changes(from: saved), to: app, bottleConfig: bottle)
        let actual = GraphicsOptions.load(from: bottle, inheriting: app.globalConfig)
        XCTAssertFalse(actual.hud)
        XCTAssertFalse(actual.fpsEnabled)
        XCTAssertEqual(CXConfig.value(of: "D3DM_MTL4", in: bottle), "1")
    }

    func testAppSettingsResealTheBundleWithoutErasingBottleOverrides() throws {
        let (app, _) = try fixture()
        let bottle = try write("[EnvironmentVariables]\n\"MTL_HUD_ENABLED\" = \"0\"\n", "bottle.conf")
        try AppSettings.apply([("MTL_HUD_ENABLED", "1")], to: app)
        try assertSigned(app.url)
        XCTAssertEqual(CXConfig.value(of: "MTL_HUD_ENABLED", in: bottle), "0")
        XCTAssertEqual(CXConfig.value(of: "UNRELATED", in: app.globalConfig), "keep")
    }

    func testFileBackupRestoresContentsPermissionsAndAbsentFiles() throws {
        let existing = try write("old", "existing")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: existing.path)
        let new = root.appendingPathComponent("new")
        let backup = try FileBackup()
        try backup.capture(existing)
        try backup.capture(new)
        try Data("new".utf8).write(to: existing)
        try Data().write(to: new)
        XCTAssertTrue(backup.restore().isEmpty)
        XCTAssertEqual(try String(contentsOf: existing), "old")
        XCTAssertTrue(fm.isExecutableFile(atPath: existing.path))
        XCTAssertFalse(fm.fileExists(atPath: new.path))
    }

    func testQuarantineRemovalIsCheckedAndCanBeRolledBack() throws {
        let child = try write("payload", "bundle/file")
        let bundle = child.deletingLastPathComponent()
        try quarantine(bundle)
        try quarantine(child)
        let backup = try FileBackup()
        XCTAssertEqual(try Quarantine.strip(under: bundle, backup: backup), 2)
        XCTAssertTrue(backup.restore().isEmpty)
        XCTAssertGreaterThan(getxattr(bundle.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW), 0)
        XCTAssertThrowsError(try Quarantine.strip(under: root.appendingPathComponent("missing")))
    }

    func testOperationLockRejectsConcurrentMutationAndUnlocks() throws {
        let lock = try OperationLock(directory: root)
        XCTAssertThrowsError(try OperationLock(directory: root))
        lock.unlock()
        XCTAssertNoThrow(try OperationLock(directory: root))
    }

    func testFailedResealRestoresConfigAndOriginalSignatureFiles() throws {
        let (app, _) = try fixture()
        let beforeConfig = try Data(contentsOf: app.globalConfig)
        let main = try app.executableURL()
        let beforeExecutable = try Data(contentsOf: main)
        let resources = app.url.appendingPathComponent("Contents/_CodeSignature/CodeResources")
        let beforeResources = try Data(contentsOf: resources)
        // codesign rejects Finder metadata in a bundle. This forces a real failure after
        // settings were written without injecting a fake command runner into production code.
        let bad = try write("resource", "CrossOver.app/Contents/Resources/bad")
        let finderInfo = Data(repeating: 1, count: 32)
        let status = finderInfo.withUnsafeBytes { setxattr(bad.path, "com.apple.FinderInfo", $0.baseAddress, 32, 0, 0) }
        XCTAssertEqual(status, 0)
        XCTAssertThrowsError(try AppSettings.apply([("MTL_HUD_ENABLED", "1")], to: app))
        XCTAssertEqual(try Data(contentsOf: app.globalConfig), beforeConfig)
        XCTAssertEqual(try Data(contentsOf: main), beforeExecutable)
        XCTAssertEqual(try Data(contentsOf: resources), beforeResources)
        XCTAssertFalse(fm.fileExists(atPath: app.globalConfig.appendingPathExtension("gptkpatcher.bak").path))
    }

    func testInterruptedRepatchBackupIsNeverDeleted() throws {
        let (app, kit) = try fixture()
        let first = try PatchJob(request: request(app, kit), log: { _ in }).run()
        let patched = try CrossOverBundle(url: first)
        let previous = try patched.gptkDirectory().deletingLastPathComponent().appendingPathComponent(".apple_gptk.previous")
        try fm.createDirectory(at: previous, withIntermediateDirectories: false)
        let marker = previous.appendingPathComponent("recovery-file")
        try Data("preserve".utf8).write(to: marker)
        XCTAssertThrowsError(try PatchJob(request: request(patched, kit, mode: .inPlace), log: { _ in }).run())
        XCTAssertEqual(try String(contentsOf: marker), "preserve")
    }

    func testAChildInheritingOutputDoesNotHoldTheCommandOpen() throws {
        let start = Date()
        let result = try Shell.run("/bin/sh", ["-c", "sleep 2 & printf done"], timeout: 5)
        XCTAssertEqual(result.stdout, "done")
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
    }

    @MainActor
    func testWindowStatesRenderAtUsableSizes() async throws {
        let (app, kit) = try fixture()
        let engine = PatchEngine()
        engine.setCrossOver(app.url)
        engine.selectedToolkit = kit
        engine.toolkits = [kit]
        engine.useTemporaryOutputFolder(root)
        engine.patchedApps = (0..<12).map {
            PatchedApp(url: root.appendingPathComponent("CrossOver Patched \($0).app"), name: "CrossOver", gptkVersion: "4.0b2", patchedAt: nil)
        }
        let failure = Failure(title: "Couldn't patch CrossOver", message: "Could not remove download metadata from a file in CrossOver. Check that you own the app and can write to it. Recovery files are available in the location shown in Details.")
        let states: [(String, Phase)] = [("ready", .idle), ("signing", .running(.signing)), ("error", .failed(failure)), ("success", .done(app.url)), ("first-launch", .idle)]
        for (name, phase) in states {
            engine.phase = phase
            if name == "first-launch" {
                try quarantine(app.url, value: "0083;1234;Safari;")
                engine.setCrossOver(app.url)
            }
            for scheme in [ColorScheme.light, .dark] {
                let view = NSHostingView(rootView: ContentView(engine: engine, loadsData: false).environment(\.colorScheme, scheme))
                view.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
                let size = view.fittingSize
                XCTAssertEqual(size.width, 520)
                XCTAssertLessThan(size.height, 750, "\(name) exceeds a typical laptop display height")
                view.frame = NSRect(origin: .zero, size: size)
                let window = NSWindow(contentRect: view.bounds, styleMask: .borderless, backing: .buffered, defer: false)
                window.appearance = view.appearance
                window.contentView = view
                view.layoutSubtreeIfNeeded()
                if ProcessInfo.processInfo.environment["GPTKPATCHER_SNAPSHOT_DIR"] != nil {
                    window.orderFront(nil)
                    try await Task.sleep(for: .milliseconds(150))
                }
                window.displayIfNeeded()
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                if let directory = ProcessInfo.processInfo.environment["GPTKPATCHER_SNAPSHOT_DIR"] {
                    let folder = URL(fileURLWithPath: directory)
                    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                    let context = try XCTUnwrap(CGContext(data: nil, width: bitmap.pixelsWide, height: bitmap.pixelsHigh,
                        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
                    let bounds = CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
                    context.setFillColor(CGColor(gray: scheme == .light ? 0.93 : 0.16, alpha: 1))
                    context.fill(bounds)
                    context.draw(try XCTUnwrap(bitmap.cgImage), in: bounds)
                    let finalBitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
                    try XCTUnwrap(finalBitmap.representation(using: .png, properties: [:]))
                        .write(to: folder.appendingPathComponent("\(name)-\(scheme == .light ? "light" : "dark").png"))
                }
                window.orderOut(nil)
                window.contentView = nil
            }
        }
    }

    func testProcessTimeoutStopsTheChild() throws {
        let start = Date()
        XCTAssertThrowsError(try Shell.run("/bin/sleep", ["20"], timeout: 0.1))
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testProcessCancellationPropagates() throws {
        let token = CancellationToken()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { token.cancel() }
        XCTAssertThrowsError(try Shell.check("/bin/sleep", ["20"], token: token)) { XCTAssertTrue($0 is CancellationError) }
    }

    @MainActor
    func testBusyEngineRejectsInputsAndAnotherPatch() async throws {
        let (app, kit) = try fixture()
        let engine = PatchEngine()
        engine.setCrossOver(app.url)
        engine.selectedToolkit = kit
        XCTAssertTrue(engine.isReady)
        engine.phase = .running(.installing)
        XCTAssertFalse(engine.isReady)
        XCTAssertFalse(engine.route(root.appendingPathComponent("other.app")))
        engine.importToolkit(from: root.appendingPathComponent("ignored.dmg"))
        XCTAssertFalse(engine.isImporting)
        engine.patch()
        XCTAssertEqual(engine.phase, .running(.installing))
    }

    func testImportUsesAnIsolatedLibraryAndUnmountsItsImage() throws {
        let (_, kit) = try fixture()
        let image = root.appendingPathComponent("toolkit.dmg")
        try Shell.check("/usr/bin/hdiutil", ["create", "-srcfolder", kit.lib.path, "-volname", "GPTKPatcherTest", "-format", "UDZO", image.path])
        let imported = try ToolkitLibrary.importImage(image, directory: root.appendingPathComponent("Library"), log: { _ in })
        XCTAssertEqual(imported.version, "4.0b2")
        try GPTKSource.validateLib(imported.lib)
        XCTAssertEqual(ToolkitLibrary.list(directory: root.appendingPathComponent("Library")).count, 1)
        let mounts = try Shell.check("/usr/bin/hdiutil", ["info", "-plist"])
        XCTAssertFalse(mounts.stdout.contains(image.path))
    }

    func testRepairFixesAnOlderPatchWithoutChangingItsToolkitOrSettings() throws {
        let (app, kit) = try fixture()
        let result = try PatchJob(request: request(app, kit), log: { _ in }).run()
        let patched = try CrossOverBundle(url: result)
        try CXConfig.set("MTL_HUD_ENABLED", to: "0", in: patched.globalConfig)
        let invalid = try Shell.run("/usr/bin/codesign", ["--verify", "--strict", result.path])
        XCTAssertNotEqual(invalid.status, 0)
        let before = try Data(contentsOf: patched.globalConfig)
        try AppSigning.repair(patched, log: { _ in })
        try assertSigned(result)
        XCTAssertEqual(try Data(contentsOf: patched.globalConfig), before)
        XCTAssertEqual(patched.installedD3DMetalVersion, kit.version)
        XCTAssertThrowsError(try AppSigning.repair(app, log: { _ in }))
    }

    /// Opt-in integration check: the paths point to disposable stock downloads and a read-only
    /// toolkit. No app is launched, no bottle is used, and no result is added to the user's registry.
    func testOfficialCrossOverBundle() throws {
        let env = ProcessInfo.processInfo.environment
        guard let source = env["GPTKPATCHER_TEST_CROSSOVER"], let library = env["GPTKPATCHER_TEST_TOOLKIT"] else {
            throw XCTSkip("Set GPTKPATCHER_TEST_CROSSOVER and GPTKPATCHER_TEST_TOOLKIT for the official-bundle check.")
        }
        let app = try CrossOverBundle(url: URL(fileURLWithPath: source))
        let lib = URL(fileURLWithPath: library)
        let info = D3DMetalInfo.read(inLib: lib)
        let kit = Toolkit(version: try XCTUnwrap(info.version), lib: lib, importedAt: Date(), minimumOS: info.minimumOS, sourceName: nil)
        let before = try Data(contentsOf: app.globalConfig)
        let job = request(app, kit)
        let result = try PatchJob(request: job, log: { print($0) }).run()
        try assertSigned(result)
        try assertSigned(app.url)
        XCTAssertEqual(try Data(contentsOf: app.globalConfig), before)
        try AppSettings.apply([("MTL_HUD_ENABLED", "0")], to: CrossOverBundle(url: result))
        try assertSigned(result)
        let patched = try CrossOverBundle(url: result)
        XCTAssertEqual(patched.version, app.version)
        let repatched = try PatchJob(request: request(patched, kit, mode: .inPlace), log: { print($0) }).run()
        try assertSigned(repatched)
        if let output = env["GPTKPATCHER_TEST_OUTPUT"] {
            // Retain an explicitly requested integration artifact for manual launch checks.
            try fm.copyItem(at: repatched, to: URL(fileURLWithPath: output))
        }
    }
}
