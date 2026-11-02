import Foundation

public enum RepositoryOperationState: String, Sendable {
    case idle, merge, rebase, cherryPick, revert
}
public struct HistoryPage: Sendable {
    public let tip: String
    public let commits: [GitCommit]
    public let nextOffset: Int?
}

extension GitRepository {
    public func operationState(at path: String) async throws -> RepositoryOperationState {
        for (name, state) in [("rebase-merge", RepositoryOperationState.rebase), ("rebase-apply", .rebase), ("MERGE_HEAD", .merge), ("CHERRY_PICK_HEAD", .cherryPick), ("REVERT_HEAD", .revert)] {
            let file = try await run(path, ["rev-parse", "--path-format=absolute", "--git-path", name]).trimmingCharacters(in: .newlines)
            if FileManager.default.fileExists(atPath: file) { return state }
        }
        return .idle
    }

    public func history(at path: String, revision: String, offset: Int = 0, count: Int = 300) async throws -> HistoryPage {
        guard offset >= 0, count > 0, !revision.hasPrefix("-") else { throw GitFailure("Invalid history request.") }
        let tip = try await run(path, ["rev-parse", "--verify", revision + "^{commit}"]).trimmingCharacters(in: .newlines)
        let log = try await run(path, ["log", "--topo-order", "--skip=\(offset)", "-\(count + 1)", "--format=%H%x00%h%x00%an%x00%ae%x00%at%x00%s%x00%D%x00%P%x1e", tip, "--"])
        let commits = Self.parseCommits(log)
        return HistoryPage(tip: tip, commits: Array(commits.prefix(count)), nextOffset: commits.count > count ? offset + count : nil)
    }

    static func parseCommits(_ log: String) -> [GitCommit] {
        log.components(separatedBy: "\u{1e}").compactMap { entry in
            let f = entry.trimmingCharacters(in: .newlines).components(separatedBy: "\0")
            guard f.count == 8 else { return nil }
            return GitCommit(hash: f[0], shortHash: f[1], author: f[2], email: f[3], date: Date(timeIntervalSince1970: Double(f[4]) ?? 0), subject: f[5], refs: f[6], parents: f[7].split(separator: " ").map(String.init))
        }
    }
}
