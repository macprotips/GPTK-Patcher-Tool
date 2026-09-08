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
            current?.terminate()
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
    /// Runs an executable with arguments, capturing stdout and stderr without deadlocking on full pipes.
    @discardableResult
    static func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil,
                    token: CancellationToken? = nil) throws -> CommandResult {
        try token?.checkpoint()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        }
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        token?.track(process)
        defer { token?.track(nil) }
        if token?.isCancelled == true { process.terminate() }   // cancelled between run and track

        // stderr is drained on another thread so a chatty command can't fill one pipe and stall.
        let errBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errBox.data = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return CommandResult(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errBox.data, as: UTF8.self)
        )
    }

    /// Like `run` but throws when the exit status is non-zero.
    @discardableResult
    static func check(_ executable: String, _ arguments: [String], token: CancellationToken? = nil) throws -> CommandResult {
        let result = try run(executable, arguments, token: token)
        try token?.checkpoint()
        guard result.status == 0 else {
            throw PatchError.command("\(executable) \(arguments.joined(separator: " "))", result)
        }
        return result
    }
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

private final class DataBox: @unchecked Sendable {
    var data = Data()
}
