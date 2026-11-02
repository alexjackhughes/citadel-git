import Foundation

public struct GitFailure: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct ChangedFile: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let originalPath: String?
    public let index: Character
    public let worktree: Character
    public var staged: Bool { index != " " && index != "?" }
    public var unstaged: Bool { worktree != " " }
    public var conflicted: Bool { index == "U" || worktree == "U" || (index == "A" && worktree == "A") || (index == "D" && worktree == "D") }
    public var paths: [String] { [path] + (originalPath.map { [$0] } ?? []) }
    public var status: String { conflicted ? "Conflict" : index == "?" ? "Added" : index == "R" ? "Renamed" : index == "D" || worktree == "D" ? "Deleted" : "Modified" }
}

public struct GitCommit: Identifiable, Hashable, Sendable {
    public var id: String { hash }
    public let hash: String
    public let shortHash: String
    public let author: String
    public let email: String
    public let date: Date
    public let subject: String
    public let refs: String
    public let parents: [String]
}

public struct RepositorySnapshot: Sendable {
    public let path: String
    public let branch: String
    public let branches: [String]
    public let changes: [ChangedFile]
    public let commits: [GitCommit]
    public let upstream: String
    public let remotes: [String]
    public let ahead: Int
    public let behind: Int
}

public struct CommitDetail: Sendable {
    public let message: String
    public let files: [String]
}

public actor GitRepository {
    public init() {}

    @discardableResult
    public func run(_ path: String, _ arguments: [String], allowFailure: Bool = false,
                    input: Data? = nil, environment: [String: String] = [:]) async throws -> String {
        let result = try await GitProcess.execute(at: path, arguments: arguments, input: input, environment: environment, allowFailure: allowFailure)
        return result.status == 0 ? try result.text() : ""
    }

    public func root(at path: String) async throws -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return try await run(expanded, ["rev-parse", "--show-toplevel"]).trimmingCharacters(in: .newlines)
    }

    public func changes(at path: String) async throws -> [ChangedFile] {
        let entries = try await run(path, ["status", "--porcelain=v1", "-z", "--untracked-files=all"]).components(separatedBy: "\0")
        var results: [ChangedFile] = []
        var i = 0
        while i < entries.count {
            let entry = entries[i]; i += 1
            guard entry.count >= 4 else { continue }
            let status = Array(entry.prefix(2))
            let name = String(entry.dropFirst(3))
            var original: String?
            if status.contains("R") || status.contains("C"), i < entries.count { original = entries[i]; i += 1 }
            results.append(ChangedFile(path: name, originalPath: original, index: status[0], worktree: status[1]))
        }
        return results
    }

    public func snapshot(at path: String, limit: Int = 300, historyBranch: String? = nil) async throws -> RepositorySnapshot {
        _ = try await run(path, ["rev-parse", "--git-dir"])
        let branch = try await run(path, ["symbolic-ref", "--short", "-q", "HEAD"], allowFailure: true).trimmingCharacters(in: .newlines)
        let branches = try await sortedBranches(at: path)
        if let historyBranch, !branches.contains(historyBranch) { throw GitFailure("This branch no longer exists. Select History to view the current branch.") }
        let revision = historyBranch.map { "refs/heads/" + $0 } ?? "HEAD"
        let log = try await run(path, ["log", "-\(limit)", "--format=%H%x00%h%x00%an%x00%ae%x00%at%x00%s%x00%D%x00%P%x1e", revision, "--"], allowFailure: historyBranch == nil)
        let commits: [GitCommit] = log.components(separatedBy: "\u{1e}").compactMap { entry in
            let f = entry.trimmingCharacters(in: .newlines).components(separatedBy: "\0")
            guard f.count == 8 else { return nil }
            return GitCommit(hash: f[0], shortHash: f[1], author: f[2], email: f[3], date: Date(timeIntervalSince1970: Double(f[4]) ?? 0), subject: f[5], refs: f[6], parents: f[7].split(separator: " ").map(String.init))
        }
        let upstream = try await run(path, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], allowFailure: true).trimmingCharacters(in: .newlines)
        let counts = upstream.isEmpty ? [] : try await run(path, ["rev-list", "--left-right", "--count", "HEAD...@{u}"], allowFailure: true).split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        return RepositorySnapshot(path: path, branch: branch.isEmpty ? "Detached HEAD" : branch,
                                  branches: branches,
                                  changes: try await changes(at: path), commits: commits, upstream: upstream,
                                  remotes: try await run(path, ["remote"]).split(separator: "\n").map(String.init),
                                  ahead: counts.first ?? 0, behind: counts.count == 2 ? counts[1] : 0)
    }

    private func validate(_ files: [String]) throws {
        guard !files.isEmpty, files.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("/") && !$0.components(separatedBy: "/").contains("..") }) else { throw GitFailure("Select a file inside this repository.") }
    }

    // Branch refs have no creation-date field. A retained reflog creation entry
    // (zero old object ID) is authoritative; otherwise use the tip commit date.
    private func sortedBranches(at path: String) async throws -> [String] {
        let refs = try await run(path, ["for-each-ref", "--format=%(refname:short)%00%(committerdate:unix)", "refs/heads"])
        let commonDirectory = try await run(path, ["rev-parse", "--path-format=absolute", "--git-common-dir"]).trimmingCharacters(in: .newlines)
        let branches: [(name: String, date: Int64)] = refs.split(separator: "\n").compactMap { row in
            let fields = row.components(separatedBy: "\0")
            guard fields.count == 2 else { return nil }
            let name = fields[0]
            var date = Int64(fields[1]) ?? 0
            let log = URL(fileURLWithPath: commonDirectory).appendingPathComponent("logs/refs/heads/" + name)
            if let content = try? String(contentsOf: log, encoding: .utf8),
               let first = content.split(separator: "\n").first,
               let header = first.split(separator: "\t", maxSplits: 1).first,
               let oldID = first.split(separator: " ").first,
               !oldID.isEmpty, oldID.allSatisfy({ $0 == "0" }),
               let identityEnd = header.lastIndex(of: ">") {
                let timestamp = header[header.index(after: identityEnd)...].split(whereSeparator: \.isWhitespace).first
                if let timestamp, let created = Int64(timestamp) { date = created }
            }
            return (name, date)
        }
        return branches.sorted {
            if ($0.name == "main") != ($1.name == "main") { return $0.name == "main" }
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.name < $1.name
        }.map(\.name)
    }

    private func validateRevision(_ hash: String) throws {
        guard hash.count == 40 || hash.count == 64, hash.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw GitFailure("Invalid commit reference.") }
    }

    public func detail(at path: String, commit: String) async throws -> CommitDetail {
        try validateRevision(commit)
        let message = try await run(path, ["show", "-s", "--format=%B", commit]).trimmingCharacters(in: .newlines)
        // Compare merge commits to the first parent so their actual changes are visible.
        let files = try await run(path, ["diff-tree", "--root", "--first-parent", "-m", "--no-commit-id", "--name-only", "-r", "-z", commit]).split(separator: "\0").map(String.init)
        return CommitDetail(message: message, files: Array(NSOrderedSet(array: files)) as? [String] ?? files)
    }

    public func diff(at path: String, file: String, staged: Bool = false, commit: String? = nil) async throws -> String {
        try validate([file])
        var text: String
        if let commit {
            try validateRevision(commit)
            text = try await run(path, ["show", "--format=", "--first-parent", "--diff-merges=first-parent", "--no-ext-diff", "--no-textconv", commit, "--", file])
        } else if staged {
            text = try await run(path, ["diff", "--cached", "--no-ext-diff", "--no-textconv", "--", file])
        } else {
            // Most previews need only a path-scoped diff, not a repository-wide status scan.
            text = try await run(path, ["diff", "--no-ext-diff", "--no-textconv", "--", file])
            if text.isEmpty {
                let status = try await run(path, ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--", file])
                if status.hasPrefix("?? ") {
                    let root = URL(fileURLWithPath: path).resolvingSymlinksInPath()
                    let target = root.appendingPathComponent(file).resolvingSymlinksInPath()
                    guard target.path.hasPrefix(root.path + "/") else { throw GitFailure("This symbolic link points outside the repository.") }
                    let handle = try FileHandle(forReadingFrom: target)
                    defer { try? handle.close() }
                    let bytes = try handle.readToEnd() ?? Data()
                    if bytes.contains(0) { return "Binary file — no text preview available." }
                    var lines = String(decoding: bytes, as: UTF8.self).components(separatedBy: "\n")
                    if lines.last == "" { lines.removeLast() }
                    text = lines.map { "+" + $0 }.joined(separator: "\n")

                }
            }
        }
        return text
    }

    public func stage(at path: String, files: [String]) async throws {
        try await withMutation(at: path) {
        try validate(files)
        let conflicts = try await changes(at: path).filter { $0.conflicted && files.contains($0.path) }
        for file in conflicts {
            let snapshot = try await conflict(at: path, file: file.path)
            if let text = snapshot.result, ConflictBlock.hasMarkers(text) { throw GitFailure("Resolve conflict markers in \(file.path) before staging.") }
        }
        try await run(path, ["add", "--"] + files)
            }
    }

    public func unstage(at path: String, files: [String]) async throws {
        try await withMutation(at: path) {
        try validate(files)
        let hasHead = try await !run(path, ["rev-parse", "--verify", "HEAD"], allowFailure: true).isEmpty
        try await run(path, hasHead ? ["restore", "--staged", "--"] + files : ["rm", "--cached", "--"] + files)
            }
    }

    public func commit(at path: String, message: String) async throws {
        try await withMutation(at: path) {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw GitFailure("Write a commit message first.") }
        try await run(path, ["commit", "-m", message])
            }
    }

    public func switchBranch(at path: String, branch: String, create: Bool = false) async throws {
        try await withMutation(at: path) {
        guard !branch.isEmpty, !branch.hasPrefix("-") else { throw GitFailure("Enter a valid branch name.") }
        try await run(path, ["check-ref-format", "--branch", branch])
        try await run(path, create ? ["switch", "-c", branch] : ["switch", "--", branch])
            }
    }

    public func sync(at path: String, operation: String) async throws {
        _ = try await withMutation(at: path) {
        switch operation {
        case "fetch": try await run(path, ["fetch", "--all"])
        case "pull": try await run(path, ["pull", "--ff-only"])
        case "push": try await run(path, ["push"])
        default: throw GitFailure("Unknown Git operation.")
        }
            }
    }
}
