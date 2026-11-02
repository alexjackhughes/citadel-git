import Foundation
import Darwin

public enum GitOperationEvent: Sendable {
    case started(Date)
    case output(String)
    case finished(Int32)
}

public enum GitOperation {
    @TaskLocal public static var onEvent: (@Sendable (GitOperationEvent) -> Void)?
}

public final class GitOutput: @unchecked Sendable {
    public let directory: URL
    public let stdout: URL
    public let stderr: URL
    public let status: Int32
    init(directory: URL, status: Int32) {
        self.directory = directory; self.status = status
        stdout = directory.appendingPathComponent("stdout")
        stderr = directory.appendingPathComponent("stderr")
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
    public func text() throws -> String { String(decoding: try Data(contentsOf: stdout), as: UTF8.self) }
}

public enum GitProcess {
    public static func redact(_ text: String) -> String {
        text.replacingOccurrences(of: #"(https?://)[^\s/@]+@"#, with: "$1[redacted]@", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)(token|password|access_token)=([^\s&]+)"#, with: "$1=[redacted]", options: .regularExpression)
    }
    private static func worker() -> URL? {
        let roots = [Bundle.main.bundleURL, URL(fileURLWithPath: CommandLine.arguments[0])] + Bundle.allBundles.map(\.bundleURL)
        for root in roots {
            var directory = root.deletingLastPathComponent()
            for _ in 0..<6 {
                let candidate = directory.appendingPathComponent("CitadelGitWorker")
                if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
                directory.deleteLastPathComponent()
            }
        }
        return nil
    }
    public static func execute(at path: String, arguments: [String], input: Data? = nil,
                               environment: [String: String] = [:], allowFailure: Bool = false) async throws -> GitOutput {
        try Task.checkCancellation()
        let control = ProcessControl()
        let event = GitOperation.onEvent
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("citadel-operation-\(UUID().uuidString)")
                    do {
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                        let process = Process()
                        let helper = worker()
                        process.executableURL = helper ?? URL(fileURLWithPath: "/usr/bin/git")
                        // Do not export literal pathspec mode into Git's own stash/rebase helpers.
                        let pathCommands = ["diff", "show", "status", "add", "restore", "rm", "ls-files", "diff-tree", "checkout-index"]
                        process.arguments = (pathCommands.contains(arguments.first ?? "") ? ["--literal-pathspecs"] : []) + ["-C", path] + arguments
                        var env = ProcessInfo.processInfo.environment
                        env["GIT_TERMINAL_PROMPT"] = "0"
                        env["GIT_OPTIONAL_LOCKS"] = "0"
                        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
                        environment.forEach { env[$0.key] = $0.value }
                        process.environment = env
                        let out = Pipe(), err = Pipe(), stdin = Pipe()
                        process.standardOutput = out; process.standardError = err
                        if let input {
                            let inputURL = directory.appendingPathComponent("stdin")
                            try input.write(to: inputURL)
                            process.standardInput = try FileHandle(forReadingFrom: inputURL)
                        } else { process.standardInput = FileHandle.nullDevice }
                        _ = stdin // Input uses a file so large patches cannot deadlock a pipe.
                        let group = DispatchGroup()
                        for (pipe, name) in [(out, "stdout"), (err, "stderr")] {
                            let url = directory.appendingPathComponent(name)
                            FileManager.default.createFile(atPath: url.path, contents: nil)
                            let handle = try FileHandle(forWritingTo: url)
                            group.enter()
                            DispatchQueue.global(qos: .userInitiated).async {
                                defer { try? handle.close(); group.leave() }
                                while true {
                                    let data = pipe.fileHandleForReading.availableData
                                    if data.isEmpty { break }
                                    try? handle.write(contentsOf: data)
                                    if name == "stderr" { event?(.output(redact(String(decoding: data, as: UTF8.self)))) }
                                }
                            }
                        }
                        do { try control.launch(process, grouped: helper != nil) }
                        catch {
                            try? out.fileHandleForWriting.close(); try? err.fileHandleForWriting.close()
                            group.wait(); throw error
                        }
                        event?(.started(Date()))
                        process.waitUntilExit()
                        group.wait()
                        if let handle = process.standardInput as? FileHandle, input != nil { try? handle.close() }
                        control.finish()
                        let result = GitOutput(directory: directory, status: process.terminationStatus)
                        event?(.finished(result.status))
                        if control.wasCancelled { throw CancellationError() }
                        if result.status != 0 && !allowFailure {
                            let bytes = try Data(contentsOf: result.stderr)
                            let message = redact(String(decoding: bytes.suffix(16_384), as: UTF8.self)).trimmingCharacters(in: .whitespacesAndNewlines)
                            throw GitFailure(message.isEmpty ? "Git exited with status \(result.status)." : message)
                        }
                        continuation.resume(returning: result)
                    } catch {
                        try? FileManager.default.removeItem(at: directory)
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: { control.cancel() }
    }
}

private final class ProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var grouped = false
    private var cancelled = false
    var wasCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func launch(_ process: Process, grouped: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        try process.run()
        self.process = process; self.grouped = grouped
    }
    func finish() { lock.lock(); process = nil; lock.unlock() }
    func cancel() {
        lock.lock(); cancelled = true
        signal(SIGTERM)
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
            lock.lock(); defer { lock.unlock() }; signal(SIGKILL)
        }
    }
    private func signal(_ value: Int32) {
        guard let process else { return }
        // The worker may not have entered setsid yet; signal the root as well.
        if grouped { _ = kill(-process.processIdentifier, value) }
        if process.isRunning { _ = kill(process.processIdentifier, value) }
    }
}
