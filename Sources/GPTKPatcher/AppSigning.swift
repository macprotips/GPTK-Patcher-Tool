import Foundation

enum AppSigning {
    static func repair(_ bundle: CrossOverBundle, token: CancellationToken? = nil, log: (String) -> Void) throws {
        guard bundle.hasPatchBackup else {
            throw PatchError.io("Launch repair is only for an app previously patched by GPTK Patcher. Use a fresh CodeWeavers download for an unrecognized app.")
        }
        let lock = try OperationLock()
        defer { lock.unlock() }
        try bundle.requireNotRunning()
        let backup = try FileBackup()
        do { try seal(bundle, backup: backup, token: token, log: log) }
        catch {
            let failures = backup.restore()
            if !failures.isEmpty { throw PatchError.io("\(error.localizedDescription) \(failures.joined(separator: " "))") }
            throw error
        }
    }

    /// A modified bundle needs a new resource seal. Opening a stock app once does not validate
    /// its later modifications, and an approved quarantine flag can be inherited by a clone.
    static func validateSource(_ bundle: CrossOverBundle, token: CancellationToken, log: (String) -> Void) throws {
        if bundle.hasPatchBackup {
            log("Previously patched CrossOver; its local signature will be renewed.")
            return
        }
        let result = try Shell.run("/usr/bin/codesign", ["--verify", "--strict", bundle.url.path], token: token)
        try token.checkpoint()
        guard result.status == 0 else {
            throw PatchError.io("The original CrossOver's signature is invalid. Start with a fresh CrossOver download from CodeWeavers, then patch that copy. \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        log("Verified the original CrossOver signature.")
    }

    static func seal(_ bundle: CrossOverBundle, backup: FileBackup, token: CancellationToken? = nil,
                     log: (String) -> Void) throws {
        let executable = try bundle.executableURL()
        let signature = bundle.url.appendingPathComponent("Contents/_CodeSignature")
        try FileSafety.requireContained(signature, in: bundle.url)
        try backup.capture(executable)
        try backup.capture(signature)

        let result = try Shell.check("/usr/bin/codesign", ["--display", "--entitlements", "-", "--xml", bundle.url.path], token: token)
        var entitlements: [String: Any] = [:]
        if !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let parsed = try PropertyListSerialization.propertyList(from: Data(result.stdout.utf8), format: nil) as? [String: Any] else {
                throw PatchError.io("Could not read CrossOver's signing entitlements.")
            }
            entitlements = parsed
        }
        // The main executable now has a local identity; its unchanged Python/Sparkle libraries
        // still have CodeWeavers' identity. Keep their signatures and allow that combination.
        entitlements["com.apple.security.cs.disable-library-validation"] = true
        let plist = backup.directory.appendingPathComponent("entitlements.plist")
        try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0).write(to: plist)
        log("Signing the modified app locally, preserving its embedded libraries and entitlements…")
        try Shell.check("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none",
                         "--preserve-metadata=identifier,flags,runtime", "--entitlements", plist.path, bundle.url.path], token: token)
        let cleared = try Quarantine.strip(under: bundle.url, backup: backup, token: token)
        if cleared > 0 { log("Cleared download metadata from \(cleared) item(s) in the local patched app.") }
        try Shell.check("/usr/bin/codesign", ["--verify", "--deep", "--strict", bundle.url.path], token: token)
        log("Verified the patched app's signature. This is a local build, not a CodeWeavers-signed distribution.")
    }
}

enum Quarantine {
    private static let name = "com.apple.quarantine"

    /// The download's approval marker is a first-open hint, not a complete launch history.
    /// ponytail: copies can lose or inherit this metadata; only block a recorded pending approval.
    static func hasPendingApproval(at url: URL) throws -> Bool {
        let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        if size < 0 {
            if errno == ENOATTR || errno == ENOTSUP { return false }
            throw PatchError.io("Could not check CrossOver's first-launch approval: \(String(cString: strerror(errno))).")
        }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        guard read >= 0 else { throw PatchError.io("Could not read CrossOver's first-launch approval. Add the app again to retry.") }
        guard let marker = String(data: data.prefix(read), encoding: .utf8),
              let field = marker.split(separator: ";", omittingEmptySubsequences: false).first,
              let flags = UInt32(field, radix: 16) else { return false }
        // QTN_FLAG_USER_APPROVED, also declared in Apple's WebKit QuarantineSPI.h.
        return flags & 0x0040 == 0
    }

    @discardableResult
    static func strip(under root: URL, backup: FileBackup? = nil, token: CancellationToken? = nil) throws -> Int {
        var count = 0
        func clear(_ url: URL) throws {
            try token?.checkpoint()
            let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
            if size < 0 {
                if errno == ENOATTR || errno == ENOTSUP { return }
                throw PatchError.io("Could not check download metadata on \(url.path): \(String(cString: strerror(errno))).")
            }
            var data = Data(count: size)
            let read = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
            guard read >= 0 else { throw PatchError.io("Could not read download metadata on \(url.path).") }
            backup?.captureQuarantine(url, data: data)
            guard removexattr(url.path, name, XATTR_NOFOLLOW) == 0 else {
                throw PatchError.io("Could not remove download metadata from \(url.path): \(String(cString: strerror(errno))). The app may be reported as damaged; check that you own the app and can write to it.")
            }
            count += 1
        }
        try clear(root)
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
            errorHandler: { _, error in enumerationError = error; return false }) else {
            throw PatchError.io("Could not inspect files in \(root.path).")
        }
        for case let url as URL in enumerator { try clear(url) }
        if let enumerationError { throw enumerationError }
        return count
    }
}
