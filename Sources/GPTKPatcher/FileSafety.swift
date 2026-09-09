import Foundation

enum FileSafety {
    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
            || (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    static func contains(_ child: URL, in parent: URL) -> Bool {
        let root = parent.resolvingSymlinksInPath().standardizedFileURL.path
        let path = child.resolvingSymlinksInPath().standardizedFileURL.path
        return path.hasPrefix(root + "/")
    }

    static func requireContained(_ child: URL, in parent: URL) throws {
        guard contains(child, in: parent) else {
            throw PatchError.io("An app or toolkit file points outside its folder: \(child.path). Use a fresh copy of the download.")
        }
    }

    static func isSafeComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".."
            && value.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\:").union(.controlCharacters)) == nil
    }
}

/// Serializes mutations across GUI and CLI processes; the OS releases the lock after a crash.
/// ponytail: one lock for all apps/toolkits; use per-app locks only if concurrent patching is needed.
final class OperationLock {
    private var descriptor: Int32 = -1
    private static let stateLock = NSLock()
    private static var held = 0
    static var isHeld: Bool { stateLock.withLock { held > 0 } }

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/GPTKPatcher")) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        descriptor = open(directory.appendingPathComponent(".operation.lock").path,
                          O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            descriptor = -1
            throw PatchError.io("Another patch, toolkit import, or settings change is in progress. Wait for it to finish, then try again.")
        }
        Self.stateLock.withLock { Self.held += 1 }
    }

    func unlock() {
        if descriptor >= 0 {
            flock(descriptor, LOCK_UN); close(descriptor); descriptor = -1
            Self.stateLock.withLock { Self.held -= 1 }
        }
    }

    deinit { unlock() }
}

/// Backups include permissions and extended attributes, including executable code signatures.
/// Failed restores retain the backup directory and report its path instead of claiming success.
final class FileBackup {
    private let fm = FileManager.default
    let directory: URL
    private var files: [(original: URL, backup: URL?)] = []
    private var quarantine: [(url: URL, data: Data)] = []
    private var retainForRecovery = false

    init() throws {
        directory = fm.temporaryDirectory.appendingPathComponent("GPTKPatcher-backup-\(UUID().uuidString)")
        try fm.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    func capture(_ url: URL) throws {
        guard !files.contains(where: { $0.original == url }) else { return }
        var backup: URL?
        if FileSafety.exists(url) {
            let target = directory.appendingPathComponent(String(files.count))
            try fm.copyItem(at: url, to: target)
            backup = target
        }
        files.append((url, backup))
    }

    func captureQuarantine(_ url: URL, data: Data) {
        quarantine.append((url, data))
    }

    func keepForRecovery() { retainForRecovery = true }

    func restore() -> [String] {
        var failures: [String] = []
        for (original, backup) in files.reversed() {
            do {
                if FileSafety.exists(original) { try fm.removeItem(at: original) }
                if let backup { try fm.copyItem(at: backup, to: original) }
            } catch { failures.append("Could not restore \(original.path): \(error.localizedDescription)") }
        }
        for (url, data) in quarantine where FileSafety.exists(url) {
            let result = data.withUnsafeBytes {
                setxattr(url.path, "com.apple.quarantine", $0.baseAddress, data.count, 0, XATTR_NOFOLLOW)
            }
            if result != 0 { failures.append("Could not restore download metadata on \(url.path).") }
        }
        if !failures.isEmpty {
            retainForRecovery = true
            failures.append("Recovery files are at \(directory.path).")
        }
        return failures
    }

    deinit { if !retainForRecovery { try? fm.removeItem(at: directory) } }
}
