import Foundation

extension GitRepository {
    public func initialize(at path: String, branch: String = "main") async throws -> String {
        try await withMutation(at: path) {
            guard !branch.isEmpty, !branch.hasPrefix("-") else { throw GitFailure("Enter a valid initial branch.") }
            let directory = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) { return try await root(at: path) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try await run(path, ["check-ref-format", "--branch", branch])
            // Never accidentally initialize a nested repository inside an existing one.
            let parentRoot = try await run(path, ["rev-parse", "--show-toplevel"], allowFailure: true).trimmingCharacters(in: .newlines)
            if !parentRoot.isEmpty { throw GitFailure("This folder is already inside a repository. Open \(parentRoot) instead.") }
            try await run(path, ["init", "-b", branch])
            return try await root(at: path)
        }
    }
    public func clone(source: String, parent: String, name: String) async throws -> String {
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !source.hasPrefix("-"), !source.contains("\n"),
              !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { throw GitFailure("Enter a repository source and a single destination folder name.") }
        if source.contains("://") {
            guard let url = URLComponents(string: source), ["https", "ssh", "file"].contains(url.scheme?.lowercased() ?? ""),
                  url.password == nil, url.query == nil, url.fragment == nil,
                  url.scheme?.lowercased() != "https" || url.user == nil else {
                throw GitFailure("Use an HTTPS, SSH, or local source without embedded credentials or query parameters. Configure Git authentication in Terminal first.")
            }
        } else if source.contains("::") { throw GitFailure("Git remote-helper sources are not supported.") }
        let destination = URL(fileURLWithPath: parent).appendingPathComponent(name).path
        return try await withMutation(at: destination) {
            guard !FileManager.default.fileExists(atPath: destination) else { throw GitFailure("The destination already exists. Choose a new folder name.") }
            do {
                try await run(parent, ["clone", "--progress", "--", source, destination])
                return try await root(at: destination)
            } catch is CancellationError { throw CancellationError() }
            catch { throw GitFailure(GitProcess.redact(error.localizedDescription) + "\n\nCheck your Git credential helper or SSH agent in Terminal. Any partial folder is preserved at \(destination). Choose a new destination to retry.") }
        }
    }
}

public struct GitStash: Identifiable, Sendable {
    public var id: String { oid }
    public let oid: String
    public let reference: String
    public let message: String
    public let date: Date
}

extension GitRepository {
    public func stashes(at path: String) async throws -> [GitStash] {
        let output = try await run(path, ["stash", "list", "--format=%H%x00%gd%x00%gs%x00%at%x1e"])
        return output.components(separatedBy: "\u{1e}").compactMap {
            let f = $0.trimmingCharacters(in: .newlines).components(separatedBy: "\0")
            guard f.count == 4 else { return nil }
            return GitStash(oid: f[0], reference: f[1], message: f[2], date: Date(timeIntervalSince1970: Double(f[3]) ?? 0))
        }
    }
    public func createStash(at path: String, message: String, includeUntracked: Bool) async throws {
        try await withMutation(at: path) {
            guard try await operationState(at: path) == .idle else { throw GitFailure("Finish the current Git operation before creating a stash.") }
            try await run(path, ["stash", "push"] + (includeUntracked ? ["--include-untracked"] : []) + ["-m", message.isEmpty ? "Citadel stash" : message])
        }
    }
    private func stashReference(at path: String, oid: String) async throws -> String {
        guard let stash = try await stashes(at: path).first(where: { $0.oid == oid }) else { throw GitFailure("This stash no longer exists. Refresh the stash list.") }
        return stash.reference
    }
    public func applyStash(at path: String, oid: String, pop: Bool = false, restoreIndex: Bool = false) async throws {
        try await withMutation(at: path) {
            _ = try await stashReference(at: path, oid: oid)
            guard try await operationState(at: path) == .idle else { throw GitFailure("Finish the current Git operation first.") }
            // Apply by immutable object ID; drop only after successful application.
            try await run(path, ["stash", "apply"] + (restoreIndex ? ["--index"] : []) + [oid])
            if pop { try await deleteStash(at: path, oid: oid) }
        }
    }
    public func deleteStash(at path: String, oid: String) async throws {
        try await withMutation(at: path) {
            let reference = try await stashReference(at: path, oid: oid)
            try await run(path, ["stash", "drop", reference])
        }
    }
    public func stashFiles(at path: String, oid: String) async throws -> [String] {
        _ = try await stashReference(at: path, oid: oid)
        let files = try await run(path, ["stash", "show", "--include-untracked", "--name-only", "-z", oid])
        return files.split(separator: "\0").map(String.init)
    }
    public func stashDiff(at path: String, oid: String, file: String) async throws -> DiffDocument {
        _ = try await stashReference(at: path, oid: oid)
        guard !file.hasPrefix("/"), !file.components(separatedBy: "/").contains("..") else { throw GitFailure("Invalid file path.") }
        // Tracked files are a parent-to-stash diff; untracked files live in parent 3.
        let tracked = try await run(path, ["diff", "--name-only", "-z", oid + "^1", oid])
        let arguments: [String]
        if tracked.split(separator: "\0").contains(Substring(file)) {
            arguments = ["diff", "--no-ext-diff", "--no-textconv", oid + "^1", oid, "--", file]
        } else {
            arguments = ["show", "--format=", "--root", "--no-ext-diff", "--no-textconv", oid + "^3", "--", file]
        }
        let output = try await GitProcess.execute(at: path, arguments: arguments)
        return try DiffDocument(output: output, file: file, staged: false, fingerprint: nil, partial: false)
    }
}
