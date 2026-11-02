import Foundation

public enum RebaseAction: String, Codable, CaseIterable, Sendable { case pick, reword, squash, fixup, drop, edit }
public struct RebaseEntry: Identifiable, Codable, Sendable {
    public var id: String { oid }
    public let oid: String
    public let subject: String
    public var action: RebaseAction
    public var message: String
    public let remoteRefs: [String]
}
public struct RebasePlan: Codable, Sendable {
    public let originalHead: String
    public let branch: String
    public let upstream: String?
    public var entries: [RebaseEntry]
}
public struct RebaseSession: Codable, Sendable {
    public let entries: [RebaseEntry]
    public let gitDirectory: String
    public let backupRef: String
    public let originalHead: String
}
public struct RebaseStatus: Sendable {
    public let editing: Bool
    public let message: String
    public let backupRef: String?
}

extension GitRepository {
    public func rebasePlan(at path: String, upstream: String?) async throws -> RebasePlan {
        let branch = try await run(path, ["symbolic-ref", "--short", "HEAD"]).trimmingCharacters(in: .newlines)
        let head = try await run(path, ["rev-parse", "HEAD"]).trimmingCharacters(in: .newlines)
        var base: String?
        if let upstream, !upstream.isEmpty {
            guard !upstream.hasPrefix("-"), !upstream.contains("\n") else { throw GitFailure("Invalid upstream revision.") }
            base = try await run(path, ["rev-parse", "--verify", upstream + "^{commit}"]).trimmingCharacters(in: .newlines)
            let check = try await GitProcess.execute(at: path, arguments: ["merge-base", "--is-ancestor", base!, head], allowFailure: true)
            guard check.status == 0 else { throw GitFailure("Choose an ancestor of the checked-out branch.") }
        }
        let range = base.map { $0 + ".." + head } ?? head
        let log = try await run(path, ["log", "--reverse", "--topo-order", "--format=%H%x00%h%x00%an%x00%ae%x00%at%x00%s%x00%D%x00%P%x1e", range, "--"])
        let commits = Self.parseCommits(log)
        guard !commits.isEmpty else { throw GitFailure("There are no commits after that upstream.") }
        guard commits.allSatisfy({ $0.parents.count <= 1 }) else { throw GitFailure("This range contains merge commits. Choose a linear range; merge-topology editing is not supported.") }
        var entries: [RebaseEntry] = []
        for commit in commits {
            let remotes = try await run(path, ["for-each-ref", "--contains", commit.hash, "--format=%(refname:short)", "refs/remotes"]).split(separator: "\n").map(String.init)
            let message = try await run(path, ["show", "-s", "--format=%B", commit.hash]).trimmingCharacters(in: .newlines)
            entries.append(RebaseEntry(oid: commit.hash, subject: commit.subject, action: .pick, message: message, remoteRefs: remotes))
        }
        return RebasePlan(originalHead: head, branch: branch, upstream: base, entries: entries)
    }
    public func validateRebasePlan(_ plan: RebasePlan) throws {
        guard !plan.entries.isEmpty, Set(plan.entries.map(\.oid)).count == plan.entries.count else { throw GitFailure("The plan is empty or contains duplicate commits.") }
        var retained = false
        for entry in plan.entries {
            guard [40, 64].contains(entry.oid.count), entry.oid.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw GitFailure("Invalid commit in rebase plan.") }
            if entry.action == .squash || entry.action == .fixup {
                guard retained else { throw GitFailure("Squash and fixup require a preceding retained commit.") }
            }
            if entry.action == .reword || entry.action == .squash {
                guard !entry.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw GitFailure("Reword and squash require a resulting commit message.") }
            }
            if entry.action != .drop { retained = true }
        }
    }
    private func gitDirectory(at path: String) async throws -> String {
        try await run(path, ["rev-parse", "--absolute-git-dir"]).trimmingCharacters(in: .newlines)
    }
    private func sessionURL(at path: String) async throws -> URL {
        URL(fileURLWithPath: try await gitDirectory(at: path)).appendingPathComponent("citadel/rebase-session.json")
    }
    private func editorURL() throws -> URL {
        let roots = [Bundle.main.bundleURL, URL(fileURLWithPath: CommandLine.arguments[0])] + Bundle.allBundles.map(\.bundleURL)
        for root in roots {
            var directory = root.deletingLastPathComponent()
            for _ in 0..<6 {
                let helper = directory.appendingPathComponent("CitadelGitEditor")
                if FileManager.default.isExecutableFile(atPath: helper.path) { return helper }
                directory.deleteLastPathComponent()
            }
        }
        throw GitFailure("The Citadel Git editor helper is missing. Rebuild the app.")
    }
    private func rebaseEnvironment(at path: String) async throws -> [String: String] {
        let session = try await sessionURL(at: path)
        guard FileManager.default.fileExists(atPath: session.path) else { return ["GIT_EDITOR": "/usr/bin/true"] }
        let helper = try editorURL().path.replacingOccurrences(of: "'", with: "'\\''")
        return ["CITADEL_REBASE_SESSION": session.path, "GIT_SEQUENCE_EDITOR": "'\(helper)' sequence", "GIT_EDITOR": "'\(helper)' message"]
    }
    public func startRebase(at path: String, plan: RebasePlan) async throws -> String {
        try await withMutation(at: path) {
            try validateRebasePlan(plan)
            guard try await operationState(at: path) == .idle, try await changes(at: path).isEmpty else { throw GitFailure("Stash or commit all changes and finish the current operation before rebasing.") }
            let fresh = try await rebasePlan(at: path, upstream: plan.upstream)
            guard fresh.originalHead == plan.originalHead, fresh.branch == plan.branch, Set(fresh.entries.map(\.oid)) == Set(plan.entries.map(\.oid)) else { throw GitFailure("The branch changed. Reload the rebase plan.") }
            _ = try editorURL()
            let backup = "refs/citadel/backups/rebase-" + UUID().uuidString.lowercased()
            try await run(path, ["update-ref", backup, plan.originalHead])
            let session = RebaseSession(entries: plan.entries, gitDirectory: try await gitDirectory(at: path), backupRef: backup, originalHead: plan.originalHead)
            let url = try await sessionURL(at: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(session).write(to: url, options: .atomic)
            do {
                try await run(path, ["rebase", "--interactive", "--no-autosquash", "--no-autostash", "--no-update-refs", "--no-rebase-merges"] + (plan.upstream.map { [$0] } ?? ["--root"]), environment: try await rebaseEnvironment(at: path))
            } catch is CancellationError { throw CancellationError() }
            catch { if try await operationState(at: path) != .rebase { throw error } }
            if try await operationState(at: path) == .idle { try? FileManager.default.removeItem(at: url) }
            return backup
        }
    }
    public func rebaseStatus(at path: String) async throws -> RebaseStatus {
        let gitDir = try await gitDirectory(at: path)
        let url = try await sessionURL(at: path)
        let session = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(RebaseSession.self, from: $0) }
        let message = try await run(path, ["log", "-1", "--format=%B"], allowFailure: true).trimmingCharacters(in: .newlines)
        return RebaseStatus(editing: FileManager.default.fileExists(atPath: gitDir + "/rebase-merge/amend"), message: message, backupRef: session?.backupRef)
    }
    public func controlRebase(at path: String, action: String) async throws {
        try await withMutation(at: path) {
            guard ["continue", "skip", "abort"].contains(action), try await operationState(at: path) == .rebase else { throw GitFailure("No rebase is active.") }
            if action == "continue", try await changes(at: path).contains(where: \.conflicted) { throw GitFailure("Resolve and stage every conflict first.") }
            do {
                try await run(path, ["rebase", "--" + action], environment: try await rebaseEnvironment(at: path))
                if try await operationState(at: path) == .idle { let url = try await sessionURL(at: path); try? FileManager.default.removeItem(at: url) }
            }
            catch is CancellationError { throw CancellationError() }
            catch { if try await operationState(at: path) != .rebase || action == "abort" { throw error } else { throw GitFailure("Rebase remains paused. " + error.localizedDescription) } }
        }
    }
    public func amendRebaseCommit(at path: String, message: String) async throws {
        try await withMutation(at: path) {
            guard try await operationState(at: path) == .rebase, try await rebaseStatus(at: path).editing,
                  !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !(try await changes(at: path).contains(where: \.conflicted)) else { throw GitFailure("Amend is available at an edit stop after resolving conflicts.") }
            try await run(path, ["commit", "--amend", "--allow-empty", "-m", message])
        }
    }
    public func controlMerge(at path: String, action: String) async throws {
        try await withMutation(at: path) {
            let state = try await operationState(at: path)
            guard [.merge, .cherryPick, .revert].contains(state), ["continue", "abort"].contains(action) else { throw GitFailure("No supported operation is active.") }
            let command = state == .cherryPick ? "cherry-pick" : state == .revert ? "revert" : "merge"
            try await run(path, [command, "--" + action], environment: ["GIT_EDITOR": "/usr/bin/true"])
        }
    }
}
