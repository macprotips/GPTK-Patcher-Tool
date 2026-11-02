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
        // CrossOver Preview ships aarch64 DXMT that upstream releases leave out.
        _ = try write("stock-x86", "CrossOver.app/Contents/SharedSupport/CrossOver/lib/dxmt/x86_64-windows/d3d11.dll")
        _ = try write("stock-arm", "CrossOver.app/Contents/SharedSupport/CrossOver/lib/dxmt/aarch64-windows/d3d11.dll")
        // CrossOver 26 keeps one MoltenVK in lib64; Preview keeps one per architecture.
        for slot in ["lib64", "lib/x86_64"] {
            let url = app.appendingPathComponent("Contents/SharedSupport/CrossOver/\(slot)/libMoltenVK.dylib")
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: url)
        }
        try Shell.check("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        let lib = root.appendingPathComponent("toolkit")
        try payload(at: lib, version: "4.0b2")
        return (try CrossOverBundle(url: app), Toolkit(version: "4.0b2", lib: lib, importedAt: Date(), minimumOS: "14.0", sourceName: "test.dmg"))
    }

    /// A library build holding only the architectures upstream DXMT actually ships.
    private func dxmtBuild(_ version: String) throws -> DXMTBuild {
        let path = root.appendingPathComponent("dxmt-\(version)")
        _ = try write("build-\(version)", "dxmt-\(version)/x86_64-windows/d3d11.dll")
        return DXMTBuild(version: version, path: path, importedAt: Date(), sourceName: "dxmt-v\(version).tar.gz")
    }

    private func payloadLib(_ version: String) throws -> URL {
        let lib = root.appendingPathComponent("toolkit-\(version)")
        try payload(at: lib, version: version)
        return lib
    }

    /// Packs a library build back into the kind of archive people download.
    private func archive(of build: DXMTBuild) throws -> URL {
        let out = root.appendingPathComponent("\(build.version).tar.gz")
        try Shell.check("/usr/bin/tar", ["-czf", out.path, "-C", build.path.deletingLastPathComponent().path,
                                         build.path.lastPathComponent])
        return out
    }

    private func dxmtDir(_ app: URL) -> URL {
        app.appendingPathComponent("Contents/SharedSupport/CrossOver/lib/dxmt")
    }

    /// A second stored build, told apart from the first by name and contents.
    private func moltenVKBuild(named name: String, binary: String) throws -> MoltenVKBuild {
        let source = root.appendingPathComponent("\(name)/libMoltenVK.dylib")
        try fm.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileSafety.exists(source) { try fm.removeItem(at: source) }
        try fm.copyItem(at: URL(fileURLWithPath: binary), to: source)
        return try MoltenVKLibrary.importBuild(source, directory: root.appendingPathComponent("mvk-library")) { _ in }
    }

    /// A stored MoltenVK build made from a real Mach-O, optionally narrowed to one architecture.
    private func moltenVKBuild(arch: String? = nil) throws -> MoltenVKBuild {
        let source = root.appendingPathComponent("mvk-source/libMoltenVK.dylib")
        try fm.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let arch {
            try Shell.check("/usr/bin/lipo", ["/usr/bin/true", "-thin", arch, "-output", source.path])
        } else {
            try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: source)
        }
        return try MoltenVKLibrary.importBuild(source, directory: root.appendingPathComponent("mvk-library")) { _ in }
    }

    private func mvkSlots(_ app: URL) -> [URL] {
        ["lib64", "lib/x86_64"].map {
            app.appendingPathComponent("Contents/SharedSupport/CrossOver/\($0)/libMoltenVK.dylib")
        }
    }

    private func request(_ app: CrossOverBundle, _ kit: Toolkit?, mode: PatchMode = .copy,
                         dxmt: DXMTBuild? = nil, moltenVK: MoltenVKBuild? = nil,
                         renameInPlace: Bool = true,
                         bottles: [BottleEnv.Bottle] = []) -> PatchRequest {
        PatchRequest(crossOver: app, toolkit: kit, dxmt: dxmt, moltenVK: moltenVK,
                     mode: mode, renameInPlace: renameInPlace,
                     destination: root.appendingPathComponent("Patched.app"),
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

    func testMoltenVKReplacesEverySlotAndKeepsEachStock() throws {
        let (app, _) = try fixture()
        let build = try moltenVKBuild()
        let result = try PatchJob(request: request(app, nil, moltenVK: build), log: { _ in }).run()
        try assertSigned(result)
        let expected = try Data(contentsOf: build.dylib)
        for slot in mvkSlots(result) {
            XCTAssertEqual(try Data(contentsOf: slot), expected, slot.path)
            XCTAssertTrue(fm.fileExists(atPath: slot.appendingPathExtension("stock").path), slot.path)
        }
        // The two cache settings ride along with the build rather than needing their own switch.
        let patched = try CrossOverBundle(url: result)
        XCTAssertEqual(CXConfig.value(of: "MVK_CONFIG_SHADER_COMPRESSION_ALGORITHM", in: patched.globalConfig), "3")
        XCTAssertEqual(CXConfig.value(of: "MVK_CONFIG_SHOULD_MAXIMIZE_CONCURRENT_COMPILATION", in: patched.globalConfig), "1")
        // Metal allows 16 sampler slots without argument buffers; these games need more.
        XCTAssertEqual(CXConfig.value(of: "MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS", in: patched.globalConfig), "1")
        // The source app was not touched: no backup was made beside its own slots.
        for slot in mvkSlots(app.url) {
            XCTAssertFalse(fm.fileExists(atPath: slot.appendingPathExtension("stock").path), slot.path)
        }
    }

    func testMoltenVKBuildForTheWrongArchitectureIsRefused() throws {
        let (app, _) = try fixture()
        // Narrow the app's slots to arm64 so an x86_64-only build cannot serve them.
        for slot in mvkSlots(app.url) {
            try fm.removeItem(at: slot)
            try Shell.check("/usr/bin/lipo", ["/usr/bin/true", "-thin", "arm64e", "-output", slot.path])
        }
        let build = try moltenVKBuild(arch: "x86_64")
        let source = try CrossOverBundle(url: app.url)
        XCTAssertThrowsError(try PatchJob(request: request(source, nil, moltenVK: build), log: { _ in }).run())
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("Patched.app").path))
        for slot in mvkSlots(app.url) {
            XCTAssertFalse(fm.fileExists(atPath: slot.appendingPathExtension("stock").path))
        }
    }

    func testCancellationAfterMoltenVKSwapRestoresEverySlot() throws {
        let (app, kit) = try fixture()
        let originals = try mvkSlots(app.url).map { try Data(contentsOf: $0) }
        let token = CancellationToken()
        XCTAssertThrowsError(try PatchJob(request: request(app, kit, mode: .inPlace, moltenVK: try moltenVKBuild()),
                                          log: { _ in },
                                          onStep: { if $0 == .signing { token.cancel() } }, token: token).run())
        for (slot, original) in zip(mvkSlots(app.url), originals) {
            XCTAssertEqual(try Data(contentsOf: slot), original, slot.path)
            XCTAssertFalse(fm.fileExists(atPath: slot.appendingPathExtension("stock").path))
        }
        try assertSigned(app.url)
    }

    func testAFailedSwapKeepsTheMoltenVKBuildThatWasAlreadyThere() throws {
        let (app, kit) = try fixture()
        let first = try moltenVKBuild(named: "doom-build", binary: "/usr/bin/true")
        let patched = try PatchJob(request: request(app, kit, moltenVK: first), log: { _ in }).run()
        let installed = try mvkSlots(patched).map { try Data(contentsOf: $0) }
        let stocks = try mvkSlots(patched).map { try Data(contentsOf: $0.appendingPathExtension("stock")) }

        // Swapping in a different build fails at the last step.
        let second = try moltenVKBuild(named: "detroit-build", binary: "/bin/echo")
        let token = CancellationToken()
        XCTAssertThrowsError(try PatchJob(request: request(CrossOverBundle(url: patched), kit, mode: .inPlace, moltenVK: second),
                                          log: { _ in },
                                          onStep: { if $0 == .signing { token.cancel() } }, token: token).run())
        // The build that was working is back — not the stock library — and the stock is still kept.
        for (index, slot) in mvkSlots(patched).enumerated() {
            XCTAssertEqual(try Data(contentsOf: slot), installed[index], slot.path)
            XCTAssertEqual(try Data(contentsOf: slot.appendingPathExtension("stock")), stocks[index], slot.path)
            XCTAssertFalse(fm.fileExists(atPath: slot.appendingPathExtension("previous").path))
        }
        try assertSigned(patched)
    }

    func testAFailedSwapKeepsTheDXMTBuildThatWasAlreadyThere() throws {
        let (app, kit) = try fixture()
        let patched = try PatchJob(request: request(app, kit, dxmt: try dxmtBuild("0.80")), log: { _ in }).run()
        let dll = dxmtDir(patched).appendingPathComponent("x86_64-windows/d3d11.dll")
        let token = CancellationToken()
        XCTAssertThrowsError(try PatchJob(request: request(CrossOverBundle(url: patched), kit, mode: .inPlace,
                                                           dxmt: try dxmtBuild("0.81")),
                                          log: { _ in },
                                          onStep: { if $0 == .signing { token.cancel() } }, token: token).run())
        XCTAssertEqual(try Data(contentsOf: dll), Data("build-0.80".utf8))
        let stock = dxmtDir(patched).deletingLastPathComponent().appendingPathComponent("dxmt.stock")
        XCTAssertEqual(try Data(contentsOf: stock.appendingPathComponent("x86_64-windows/d3d11.dll")), Data("stock-x86".utf8))
        XCTAssertFalse(fm.fileExists(atPath: dxmtDir(patched).deletingLastPathComponent()
            .appendingPathComponent(".dxmt.previous").path))
        try assertSigned(patched)
    }

    func testDXMTAloneLeavesTheToolkitUntouched() throws {
        let (app, _) = try fixture()
        let result = try PatchJob(request: request(app, nil, dxmt: try dxmtBuild("0.80")), log: { _ in }).run()
        try assertSigned(result)
        let patched = try CrossOverBundle(url: result)
        // The bundled toolkit is left exactly as it was, and no stock copy is made of it.
        XCTAssertEqual(patched.installedD3DMetalVersion, "3.0")
        XCTAssertFalse(fm.fileExists(atPath: try patched.gptkDirectory().appendingPathExtension("stock").path))
        XCTAssertEqual(try Data(contentsOf: dxmtDir(result).appendingPathComponent("x86_64-windows/d3d11.dll")), Data("build-0.80".utf8))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try Data(contentsOf: result.appendingPathComponent(PatchedAppRegistry.receiptPath))) as? [String: Any])
        XCTAssertEqual(json["dxmtVersion"] as? String, "0.80")
        XCTAssertNil(json["gptkD3DMetalVersion"])
    }

    func testPatchWithNeitherComponentIsRejected() throws {
        let (app, _) = try fixture()
        XCTAssertThrowsError(try PatchJob(request: request(app, nil), log: { _ in }).run())
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("Patched.app").path))
    }

    func testDXMTSwapKeepsStockAndTheArchesTheReleaseOmits() throws {
        let (app, kit) = try fixture()
        let result = try PatchJob(request: request(app, kit, dxmt: try dxmtBuild("0.80")), log: { _ in }).run()
        try assertSigned(result)
        let dxmt = dxmtDir(result)
        // The release's architecture is replaced...
        XCTAssertEqual(try Data(contentsOf: dxmt.appendingPathComponent("x86_64-windows/d3d11.dll")), Data("build-0.80".utf8))
        // ...and the one it does not ship is carried over rather than lost.
        XCTAssertEqual(try Data(contentsOf: dxmt.appendingPathComponent("aarch64-windows/d3d11.dll")), Data("stock-arm".utf8))
        let stock = dxmtDir(result).deletingLastPathComponent().appendingPathComponent("dxmt.stock")
        XCTAssertEqual(try Data(contentsOf: stock.appendingPathComponent("x86_64-windows/d3d11.dll")), Data("stock-x86".utf8))
        XCTAssertFalse(fm.fileExists(atPath: dxmt.appendingPathComponent(DXMTLibrary.manifestName).path))
        // The source app keeps its own DXMT.
        XCTAssertEqual(try Data(contentsOf: dxmtDir(app.url).appendingPathComponent("x86_64-windows/d3d11.dll")), Data("stock-x86".utf8))
    }

    func testCancellationAfterDXMTSwapRestoresTheOriginalDXMT() throws {
        let (app, kit) = try fixture()
        let token = CancellationToken()
        XCTAssertThrowsError(try PatchJob(request: request(app, kit, mode: .inPlace, dxmt: try dxmtBuild("0.80")),
                                          log: { _ in },
                                          onStep: { if $0 == .signing { token.cancel() } }, token: token).run())
        let dxmt = dxmtDir(app.url)
        XCTAssertEqual(try Data(contentsOf: dxmt.appendingPathComponent("x86_64-windows/d3d11.dll")), Data("stock-x86".utf8))
        XCTAssertEqual(try Data(contentsOf: dxmt.appendingPathComponent("aarch64-windows/d3d11.dll")), Data("stock-arm".utf8))
        XCTAssertFalse(fm.fileExists(atPath: dxmt.deletingLastPathComponent().appendingPathComponent("dxmt.stock").path))
        try assertSigned(app.url)
    }

    func testAPatchThatSkipsTheToolkitKeepsWhatTheAppAlreadyCarries() throws {
        let (app, kit) = try fixture()
        let first = try PatchJob(request: request(app, kit, moltenVK: try moltenVKBuild()), log: { _ in }).run()

        // DXMT only, on an app that already has a patched toolkit and a MoltenVK build.
        let result = try PatchJob(request: request(CrossOverBundle(url: first), nil, mode: .inPlace,
                                                   dxmt: try dxmtBuild("0.80")), log: { _ in }).run()
        try assertSigned(result)
        // The name lists everything the app carries, not just what this run installed. The MoltenVK
        // build's own name is deliberately absent: they are named after games, and this app is not
        // for one game. The test fixture's build reports no version, so it is just "MoltenVK".
        XCTAssertEqual(result.lastPathComponent, "CrossOver (GPTK 4.0b2, DXMT 0.80, MoltenVK).app")
        XCTAssertEqual(try CrossOverBundle(url: result).installedD3DMetalVersion, "4.0b2")
        XCTAssertTrue(try CrossOverBundle(url: result).hasPatchBackup, "the app must still be repairable")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try Data(contentsOf: result.appendingPathComponent(PatchedAppRegistry.receiptPath))) as? [String: Any])
        XCTAssertEqual(json["gptkD3DMetalVersion"] as? String, "4.0b2")
        XCTAssertEqual(json["stockD3DMetalVersion"] as? String, "3.0")
        XCTAssertNotNil(json["stockBackup"])
        XCTAssertEqual((json["dlssAliases"] as? [String])?.isEmpty, false)
        XCTAssertEqual(json["dxmtVersion"] as? String, "0.80")
        XCTAssertNotNil(json["moltenVKBuild"])
    }

    @MainActor
    func testChoosingUnchangedSurvivesARefreshAndRemovingABuildDoesNotPickAnother() async throws {
        let (_, kit) = try fixture()
        let engine = PatchEngine()
        engine.toolkits = [kit]
        engine.selectToolkit(kit)
        XCTAssertNotNil(engine.selectedToolkit)

        // Leaving the toolkit alone is a decision, not an absence of one.
        engine.clearToolkit()
        engine.refreshToolkits()
        XCTAssertNil(engine.selectedToolkit, "a refresh must not undo Unchanged")
        XCTAssertFalse(engine.hasSomethingToInstall)

        // Removing the chosen DXMT build leaves DXMT unchanged rather than installing another.
        let library = root.appendingPathComponent("dxmt-library")
        let first = try dxmtBuild("0.80"), second = try dxmtBuild("0.81")
        for build in [first, second] {
            _ = try DXMTLibrary.importArchive(try archive(of: build), directory: library) { _ in }
        }
        engine.dxmtBuilds = DXMTLibrary.list(directory: library)
        XCTAssertEqual(engine.dxmtBuilds.count, 2)
        engine.selectDXMT(try XCTUnwrap(engine.dxmtBuilds.first { $0.version == "0.81" }))
        engine.removeDXMT(try XCTUnwrap(engine.dxmtBuilds.first { $0.version == "0.81" }))
        XCTAssertNil(engine.selectedDXMT, "removing the chosen build must not select a different one")
    }

    func testTheBundledBuildIsOfferedAndCannotBeRemoved() throws {
        // A build packaged with the app, as scripts/build-app.sh puts it in Contents/Resources.
        let builtInRoot = root.appendingPathComponent("Resources/MoltenVK", isDirectory: true)
        let standard = builtInRoot.appendingPathComponent("standard", isDirectory: true)
        try fm.createDirectory(at: standard, withIntermediateDirectories: true)
        try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"),
                        to: standard.appendingPathComponent(MoltenVKLibrary.dylibName))

        let empty = root.appendingPathComponent("no-builds-added", isDirectory: true)
        try fm.createDirectory(at: empty, withIntermediateDirectories: true)
        let offered = MoltenVKLibrary.all(directory: empty, builtInRoot: builtInRoot)
        XCTAssertEqual(offered.count, 1, "the packaged build has to be there with nothing added")
        let build = try XCTUnwrap(offered.first)
        XCTAssertTrue(build.isBuiltIn)
        XCTAssertEqual(build.displayName, "Standard build")
        XCTAssertTrue(build.detail.contains("included with this app"))

        // It lives in the app bundle, so removing it must do nothing rather than delete it.
        try MoltenVKLibrary.remove(build)
        XCTAssertTrue(fm.fileExists(atPath: standard.appendingPathComponent(MoltenVKLibrary.dylibName).path))

        // Someone's own build of the same name wins, since they chose it deliberately.
        let added = root.appendingPathComponent("added-library", isDirectory: true)
        let source = root.appendingPathComponent("standard/libMoltenVK.dylib")
        try fm.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: source)
        _ = try MoltenVKLibrary.importBuild(source, directory: added) { _ in }
        let merged = MoltenVKLibrary.all(directory: added, builtInRoot: builtInRoot)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.isBuiltIn, false)
    }

    func testAnInPlacePatchCanKeepItsNameAndPath() throws {
        let (app, kit) = try fixture()
        let result = try PatchJob(request: request(app, kit, mode: .inPlace, renameInPlace: false),
                                  log: { _ in }).run()

        XCTAssertEqual(result.lastPathComponent, "CrossOver.app", "the name it had is the name it keeps")
        // An app outside Applications is still moved there, as it was before: that is about where
        // CrossOver belongs, not about what it is called.
        XCTAssertEqual(result.deletingLastPathComponent().standardizedFileURL,
                       root.appendingPathComponent("Applications").standardizedFileURL)
        // Keeping the name must not cost anything else: the patch, the backup and the receipt are
        // all as they would be with a rename.
        let patched = try CrossOverBundle(url: result)
        XCTAssertEqual(patched.installedD3DMetalVersion, "4.0b2")
        XCTAssertTrue(patched.hasPatchBackup)
        let recorded = try XCTUnwrap(PatchedAppRegistry.read(result))
        XCTAssertEqual(recorded.gptkVersion, "4.0b2")
        XCTAssertFalse(recorded.patchReplaced)
        try assertSigned(result)
    }

    func testPatchingAgainInPlaceWithoutRenamingStillFindsItsOwnPatch() throws {
        let (app, kit) = try fixture()
        let first = try PatchJob(request: request(app, kit, mode: .inPlace, renameInPlace: false),
                                 log: { _ in }).run()
        var lines: [String] = []
        let again = try PatchJob(request: request(CrossOverBundle(url: first), kit, mode: .inPlace,
                                                  renameInPlace: false),
                                 log: { lines.append($0) }).run()
        XCTAssertEqual(again.standardizedFileURL, first.standardizedFileURL,
                       "the second patch leaves it exactly where the first did")
        XCTAssertEqual(try CrossOverBundle(url: again).installedD3DMetalVersion, "4.0b2")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try Data(contentsOf: again.appendingPathComponent(PatchedAppRegistry.receiptPath))) as? [String: Any])
        // The stock D3DMetal recorded first time is carried forward rather than being replaced by
        // the 4.0b2 this copy now has, which is what makes it repairable.
        XCTAssertEqual(json["stockD3DMetalVersion"] as? String, "3.0")
    }

    func testACrossOverUpdateThatReplacedThePatchIsNoticed() throws {
        let (app, kit) = try fixture()
        let result = try PatchJob(request: request(app, kit), log: { _ in }).run()
        let patched = try XCTUnwrap(PatchedAppRegistry.read(result))
        XCTAssertEqual(patched.gptkVersion, "4.0b2")
        XCTAssertFalse(patched.patchReplaced, "a patch that is still in place reads as intact")

        // What a CrossOver update does: the bundle's own D3DMetal is back, the receipt is not.
        let info = try CrossOverBundle(url: result).gptkDirectory()
            .appendingPathComponent("external/D3DMetal.framework/Versions/A/Resources/Info.plist")
        try plist(["CFBundleShortVersionString": "3.0", "LSMinimumSystemVersion": "14.0"], at: info)
        let after = try XCTUnwrap(PatchedAppRegistry.read(result))
        XCTAssertTrue(after.patchReplaced, "the receipt says 4.0b2 and the app has 3.0")
    }

    func testACopyWithNoToolkitRecordedIsNeverCalledReplaced() throws {
        // A DXMT-only or MoltenVK-only patch records no toolkit, so there is nothing to compare
        // and the app must not accuse CrossOver of having eaten it.
        let (app, _) = try fixture()
        let result = try PatchJob(request: request(app, nil, dxmt: try dxmtBuild("0.80")), log: { _ in }).run()
        let patched = try XCTUnwrap(PatchedAppRegistry.read(result))
        XCTAssertFalse(patched.patchReplaced)
    }

    func testAnOlderToolkitIsRecognisedAsADowngrade() {
        XCTAssertTrue(D3DMetalVersion.isOlder("4.0b2", than: "4.0b3"))
        XCTAssertTrue(D3DMetalVersion.isOlder("3.0", than: "4.0b2"))
        XCTAssertTrue(D3DMetalVersion.isOlder("4.0b1", than: "4.0b2"))
        XCTAssertFalse(D3DMetalVersion.isOlder("4.0b3", than: "4.0b2"))
        XCTAssertFalse(D3DMetalVersion.isOlder("4.0b2", than: "4.0b2"), "the same build is not a downgrade")
        XCTAssertFalse(D3DMetalVersion.isOlder("4.1", than: "4.0b3"))
    }

    @MainActor
    func testTheFormWarnsWhenTheChosenToolkitIsOlderThanWhatIsInstalled() throws {
        // The fixture CrossOver ships D3DMetal 3.0; the library offers an older 2.0.
        let (app, kit) = try fixture()
        let older = root.appendingPathComponent("older-toolkit")
        try payload(at: older, version: "2.0")
        let engine = PatchEngine()
        engine.setCrossOver(app.url)
        engine.selectToolkit(Toolkit(version: "2.0", lib: older, importedAt: Date(), minimumOS: "14.0", sourceName: nil))
        let notice = try XCTUnwrap(engine.downgradeNotice)
        XCTAssertTrue(notice.contains("2.0") && notice.contains("3.0"), notice)

        // A newer toolkit is not a downgrade.
        engine.selectToolkit(kit)
        XCTAssertNil(engine.downgradeNotice)
    }

    func testTheReceiptRecordsAVersionAPersonWouldRecognise() throws {
        let (app, kit) = try fixture()
        let result = try PatchJob(request: request(app, kit), log: { _ in }).run()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try Data(contentsOf: result.appendingPathComponent(PatchedAppRegistry.receiptPath))) as? [String: Any])
        // The fixture is not a Preview build, so its short version is the one to record.
        XCTAssertEqual(json["sourceCrossOverVersion"] as? String, "26.2")
    }

    func testTheCopyIsNamedAfterTheGamesItWasSetUpFor() throws {
        XCTAssertEqual(PatchJob.components(gptk: nil, dxmt: nil, moltenVK: .some("1.4.3"),
                                           games: PatchJob.games(moltenVKBuild: "MoltenVK-standard-v1.4.3")),
                       "MoltenVK 1.4.3, DOOM + Wolf")
        // A build nobody recognises names no game, and neither does a plain toolkit swap.
        XCTAssertEqual(PatchJob.components(gptk: "4.0b2", dxmt: "0.80", moltenVK: .some("1.4.3"),
                                           games: PatchJob.games(moltenVKBuild: "my-own-build")),
                       "GPTK 4.0b2, DXMT 0.80, MoltenVK 1.4.3")
        // Nothing in a name may be a path separator.
        for tag in PatchJob.games(moltenVKBuild: "MoltenVK-standard-v1.4.3") {
            XCTAssertFalse(PatchJob.components(gptk: nil, dxmt: nil, moltenVK: nil, games: [tag]).contains("/"))
        }
    }

    func testKnownBuildsAreNamedByGameInTheMenuButNotInTheAppName() throws {
        // Published builds are recognised however they were named on the way in.
        let standard = MoltenVKLibrary.known(for: "MoltenVK-standard-v1.4.2")
        XCTAssertEqual(standard?.games, "Doom (2016) · Wolfenstein II")
        XCTAssertEqual(MoltenVKLibrary.known(for: "detroit")?.games, "Detroit: Become Human")
        // "doometernal" contains "doom", so the longer name has to win.
        XCTAssertEqual(MoltenVKLibrary.known(for: "MoltenVK-doometernal-main")?.games, "Doom Eternal")
        // Someone's own file is left as it is, with no game claimed for it.
        XCTAssertNil(MoltenVKLibrary.known(for: "libMoltenVK-experimental"))

        // The app's name carries the version, never the game a build was made for.
        XCTAssertEqual(PatchJob.components(gptk: "4.0b2", dxmt: nil, moltenVK: .some("1.4.3")),
                       "GPTK 4.0b2, MoltenVK 1.4.3")
        XCTAssertEqual(PatchJob.components(gptk: nil, dxmt: nil, moltenVK: .some(nil)), "MoltenVK")
        XCTAssertEqual(PatchJob.components(gptk: nil, dxmt: nil, moltenVK: nil), "patched")
    }

    func testRepatchWithTheSameExtrasLeavesThemUntouched() throws {
        let (app, kit) = try fixture()
        let dxmt = try dxmtBuild("0.80")
        let mvk = try moltenVKBuild()
        let first = try PatchJob(request: request(app, kit, dxmt: dxmt, moltenVK: mvk), log: { _ in }).run()

        // Only the toolkit changes; DXMT and MoltenVK are the builds already in there.
        let newer = Toolkit(version: "4.1", lib: try payloadLib("4.1"), importedAt: Date(),
                            minimumOS: "14.0", sourceName: "newer.dmg")
        var lines: [String] = []
        let result = try PatchJob(request: request(CrossOverBundle(url: first), newer, mode: .inPlace,
                                                   dxmt: dxmt, moltenVK: mvk), log: { lines.append($0) }).run()
        try assertSigned(result)
        XCTAssertEqual(D3DMetalInfo.read(inLib: try CrossOverBundle(url: result).gptkDirectory()).version, "4.1")
        XCTAssertTrue(lines.contains { $0.contains("DXMT 0.80 is already installed") }, lines.joined(separator: "\n"))
        XCTAssertTrue(lines.contains { $0.contains("is already installed") && $0.contains(mvk.name) }, lines.joined(separator: "\n"))
        XCTAssertFalse(fm.fileExists(atPath: dxmtDir(result).deletingLastPathComponent()
            .appendingPathComponent(".dxmt.previous").path))
        // Both are still in place, and the receipt still records them.
        XCTAssertEqual(try Data(contentsOf: dxmtDir(result).appendingPathComponent("x86_64-windows/d3d11.dll")),
                       Data("build-0.80".utf8))
        for slot in mvkSlots(result) {
            XCTAssertTrue(fm.fileExists(atPath: slot.appendingPathExtension("stock").path))
        }
        let json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try Data(contentsOf: result.appendingPathComponent(PatchedAppRegistry.receiptPath))) as? [String: Any])
        XCTAssertEqual(json["dxmtVersion"] as? String, "0.80")
        XCTAssertEqual(json["moltenVKBuild"] as? String, mvk.name)
        XCTAssertEqual((json["moltenVKSlots"] as? [String])?.count, 2)
    }

    func testRepatchWithADifferentDXMTStillSwapsIt() throws {
        let (app, kit) = try fixture()
        let first = try PatchJob(request: request(app, kit, dxmt: try dxmtBuild("0.80")), log: { _ in }).run()
        let result = try PatchJob(request: request(CrossOverBundle(url: first), kit, mode: .inPlace,
                                                   dxmt: try dxmtBuild("0.81")), log: { _ in }).run()
        XCTAssertEqual(try Data(contentsOf: dxmtDir(result).appendingPathComponent("x86_64-windows/d3d11.dll")),
                       Data("build-0.81".utf8))
        // The stock kept by the first patch is still the CrossOver original, not the 0.80 build.
        let stock = dxmtDir(result).deletingLastPathComponent().appendingPathComponent("dxmt.stock")
        XCTAssertEqual(try Data(contentsOf: stock.appendingPathComponent("x86_64-windows/d3d11.dll")), Data("stock-x86".utf8))
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

    func testFrameRateCapCoversDXMTAndKeepsItsOtherOptions() throws {
        let (app, kit) = try fixture()
        // A DXMT option someone set by hand, which must survive a cap change.
        let conf = try write("[EnvironmentVariables]\n\"DXMT_CONFIG\" = \"dxgi.forceSDR=True\"\n", "bottle/cxbottle.conf")
        let bottle = BottleEnv.Bottle(name: "Fixture", conf: conf)
        _ = try PatchJob(request: request(app, kit, bottles: [bottle]), log: { _ in }).run()
        XCTAssertEqual(CXConfig.value(of: "D3DM_MAX_FPS", in: conf), "120")
        XCTAssertEqual(CXConfig.value(of: "DXMT_CONFIG", in: conf), "dxgi.forceSDR=True;d3d11.preferredMaxFrameRate=120")

        // Reading it back offers one cap, and turning it off zeroes both limiters.
        var options = GraphicsOptions.load(from: conf)
        XCTAssertTrue(options.fpsEnabled)
        XCTAssertEqual(options.fpsValue, 120)
        let saved = options
        options.fpsEnabled = false
        try CXConfig.apply(options.changes(from: saved), to: conf)
        XCTAssertEqual(CXConfig.value(of: "D3DM_MAX_FPS", in: conf), "0")
        XCTAssertEqual(CXConfig.value(of: "DXMT_CONFIG", in: conf), "dxgi.forceSDR=True;d3d11.preferredMaxFrameRate=0")
        XCTAssertFalse(GraphicsOptions.load(from: conf).fpsEnabled)
    }

    func testResetKeepsDXMTOptionsThisAppDidNotSet() throws {
        let app = try write("[EnvironmentVariables]\n\"DXMT_CONFIG\" = \"d3d11.metalSpatialUpscaleFactor=1.5\"\n", "defaults/CrossOver.conf")
        let bottle = try write("[EnvironmentVariables]\n\"DXMT_CONFIG\" = \"dxgi.forceSDR=True;d3d11.preferredMaxFrameRate=60\"\n\"D3DM_MAX_FPS\" = \"60\"\n", "reset/cxbottle.conf")
        let options = GraphicsOptions.load(from: bottle, inheriting: app)
        XCTAssertEqual(options.dxmtOptions, ["dxgi.forceSDR=True"])
        XCTAssertEqual(options.inheritedDXMTOptions, ["d3d11.metalSpatialUpscaleFactor=1.5"])

        try CXConfig.apply(options.reset(), to: bottle)
        // The cap and the other keys this app owns are gone; the hand-set DXMT option stays.
        XCTAssertNil(CXConfig.value(of: "D3DM_MAX_FPS", in: bottle))
        XCTAssertEqual(CXConfig.value(of: "DXMT_CONFIG", in: bottle), "dxgi.forceSDR=True")
    }

    func testABottleCapCarriesTheAppWideDXMTOptionsAlong() throws {
        let app = try write("[EnvironmentVariables]\n\"DXMT_CONFIG\" = \"d3d11.metalSpatialUpscaleFactor=1.5\"\n", "carry-defaults/CrossOver.conf")
        let bottle = try write("[EnvironmentVariables]\n", "carry/cxbottle.conf")
        var options = GraphicsOptions.load(from: bottle, inheriting: app)
        let saved = options
        options.fpsEnabled = true
        options.fpsValue = 30
        try CXConfig.apply(options.changes(from: saved), to: bottle)
        // DXMT reads one string, so the bottle's own value has to carry what it would have inherited.
        XCTAssertEqual(CXConfig.value(of: "DXMT_CONFIG", in: bottle),
                       "d3d11.metalSpatialUpscaleFactor=1.5;d3d11.preferredMaxFrameRate=30")
    }

    func testDXMTOnlyCapIsReadBackAsTheCap() throws {
        let conf = try write("[EnvironmentVariables]\n\"DXMT_CONFIG\" = \"d3d11.preferredMaxFrameRate = 45\"\n", "dxmt-only/cxbottle.conf")
        let options = GraphicsOptions.load(from: conf)
        XCTAssertTrue(options.fpsEnabled)
        XCTAssertEqual(options.fpsValue, 45)
        XCTAssertEqual(options.dxmtOptions, [])
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
        // The success state lists what the app carries, so it needs a receipt to read. Writing one
        // is enough; running a whole patch here would only test the patch again.
        let patched = app.url
        try Data("""
            {"tool": "GPTKPatcher test", "date": "2026-01-01T00:00:00Z", "sourceCrossOver": "/x",
             "sourceCrossOverVersion": "26.2", "gptkD3DMetalVersion": "4.0b2", "dxmtVersion": "0.80",
             "moltenVKBuild": "standard", "environment": {}}
            """.utf8).write(to: patched.appendingPathComponent(PatchedAppRegistry.receiptPath))
        let states: [(String, Phase)] = [("ready", .idle), ("with-builds", .idle), ("signing", .running(.signing)), ("error", .failed(failure)), ("success", .done(patched)), ("first-launch", .idle)]
        for (name, phase) in states {
            engine.phase = phase
            // The extra rows always show, so this case is ready with both builds chosen.
            if name == "with-builds" {
                engine.selectedDXMT = try dxmtBuild("0.80")
                engine.selectMoltenVK(try moltenVKBuild())
            }
            if name == "first-launch" {
                try quarantine(app.url, value: "0083;1234;Safari;")
                engine.setCrossOver(app.url)
            }
            for scheme in [ColorScheme.light, .dark] {
                let view = NSHostingView(rootView: ContentView(engine: engine, loadsData: false).environment(\.colorScheme, scheme))
                view.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
                let size = view.fittingSize
                XCTAssertEqual(size.width, 760)
                // Worst case is everything showing at once: copy mode with a full patched list.
                // The floor is a 13-inch Mac at its default 1440x900, which leaves about 847
                // points of window height under the menu bar and title bar.
XCTAssertLessThan(size.height, 840, "\(name) exceeds a typical laptop display height")
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
