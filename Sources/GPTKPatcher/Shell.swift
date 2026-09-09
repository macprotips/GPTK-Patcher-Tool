import Foundation

struct CommandResult: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String
}

/// Cooperative cancellation for a running job. Cancelling also terminates the child process
/// currently being waited on, so a long copy stops promptly.
final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var current: Process?

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() {
        lock.withLock {
            cancelled = true
            if let current { Self.stop(current) }
        }
    }

    static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    fileprivate func track(_ process: Process?) {
        lock.withLock { current = process }
    }

    func checkpoint() throws {
        if isCancelled { throw CancellationError() }
    }
}

enum Shell {
    /// Capture to private files so neither full pipes nor an inherited child-process pipe can
    /// strand cancellation. All callers use argument arrays, never a shell-interpolated command.
    @discardableResult
    static func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil,
                    token: CancellationToken? = nil, timeout: TimeInterval = 900) throws -> CommandResult {
        try token?.checkpoint()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        }
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("GPTKPatcher-command-\(UUID().uuidString)")
        try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: directory) }
        let stdout = directory.appendingPathComponent("stdout")
        let stderr = directory.appendingPathComponent("stderr")
        guard fm.createFile(atPath: stdout.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              fm.createFile(atPath: stderr.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw PatchError.io("Could not create command output files. Check free disk space.")
        }
        let out = try FileHandle(forWritingTo: stdout)
        let err = try FileHandle(forWritingTo: stderr)
        defer { try? out.close(); try? err.close() }
        process.standardOutput = out
        process.standardError = err
        try process.run()
        token?.track(process)
        defer { token?.track(nil) }
        if token?.isCancelled == true { CancellationToken.stop(process) }
        let timedOut = TimeoutState()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler {
            if process.isRunning {
                timedOut.expire()
                CancellationToken.stop(process)
            }
        }
        timer.resume()
        defer { timer.cancel() }

        process.waitUntilExit()
        if timedOut.expired { throw PatchError.io("\(URL(fileURLWithPath: executable).lastPathComponent) took too long and was stopped. Try again after checking the disk and available space.") }
        return CommandResult(
            status: process.terminationStatus,
            stdout: String(decoding: try Data(contentsOf: stdout), as: UTF8.self),
            stderr: String(decoding: try Data(contentsOf: stderr), as: UTF8.self)
        )
    }

    /// Like `run` but throws when the exit status is non-zero.
    @discardableResult
    static func check(_ executable: String, _ arguments: [String], token: CancellationToken? = nil,
                      timeout: TimeInterval = 900) throws -> CommandResult {
        let result = try run(executable, arguments, token: token, timeout: timeout)
        try token?.checkpoint()
        guard result.status == 0 else {
            throw PatchError.command("\(executable) \(arguments.joined(separator: " "))", result)
        }
        return result
    }
}

private final class TimeoutState: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var expired: Bool { lock.withLock { value } }
    func expire() { lock.withLock { value = true } }
}

enum PatchError: LocalizedError {
    case notCrossOver(String)
    case unsupportedLayout(String)
    case notGPTK(String)
    case destinationExists(String)
    case command(String, CommandResult)
    case io(String)

    var errorDescription: String? {
        switch self {
        case .notCrossOver(let why): return "That isn't a CrossOver app: \(why)"
        case .unsupportedLayout(let why): return "Unsupported CrossOver layout: \(why)"
        case .notGPTK(let why): return "That doesn't look like a Game Porting Toolkit disk image: \(why)"
        case .destinationExists(let path): return "\(path) already exists."
        case .command(let cmd, let result):
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "`\(cmd)` exited with status \(result.status)\(detail.isEmpty ? "" : ": \(detail)")"
        case .io(let why): return why
        }
    }
}

extension FileManager {
    func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}

/// CLI interrupts use the same rollback path as the GUI's Cancel button.
final class SignalCancellation {
    private var sources: [DispatchSourceSignal] = []
    init(token: CancellationToken) {
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { token.cancel() }
            source.resume()
            sources.append(source)
        }
    }
    func stop() { for source in sources { source.cancel() }; sources = [] }
}
