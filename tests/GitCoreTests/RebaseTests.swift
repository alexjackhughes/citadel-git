import XCTest
@testable import GitCore

final class RebaseTests: XCTestCase {
    var directory: URL!
    var path: String { directory.path }
    let git = GitRepository()
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("citadel-rebase-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await git.run(path, ["init", "-b", "main"])
        try await git.run(path, ["config", "user.name", "Test"])
        try await git.run(path, ["config", "user.email", "test@example.com"])
        try await git.run(path, ["config", "commit.gpgsign", "false"])
    }
    override func tearDown() async throws { try FileManager.default.removeItem(at: directory) }
    func commitFile(_ name: String, text: String? = nil) async throws {
        try (text ?? name + "\n").write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        try await git.stage(at: path, files: [name]); try await git.commit(at: path, message: name)
    }
    func testRewordSquashFixupDropEditContinueAndBackup() async throws {
        for file in ["base", "a", "b", "c", "d", "e"] { try await commitFile(file) }
        var plan = try await git.rebasePlan(at: path, upstream: nil)
        plan.entries[1].action = .reword; plan.entries[1].message = "Renamed A"
        plan.entries[2].action = .squash; plan.entries[2].message = "Combined feature"
        plan.entries[3].action = .fixup
        plan.entries[4].action = .drop
        plan.entries[5].action = .edit
        let backup = try await git.startRebase(at: path, plan: plan)
        let original = try await git.run(path, ["rev-parse", backup]).trimmingCharacters(in: .newlines)
        XCTAssertEqual(original, plan.originalHead)
        let state = try await git.operationState(at: path); XCTAssertEqual(state, .rebase)
        // Reconstruct a new service instance to exercise on-disk recovery.
        let reopened = GitRepository()
        let status = try await reopened.rebaseStatus(at: path)
        XCTAssertTrue(status.editing); XCTAssertEqual(status.backupRef, backup)
        try await reopened.amendRebaseCommit(at: path, message: "Edited E")
        try await reopened.controlRebase(at: path, action: "continue")
        let complete = try await git.operationState(at: path); XCTAssertEqual(complete, .idle)
        let history = try await git.history(at: path, revision: "HEAD")
        XCTAssertEqual(history.commits.map(\.subject), ["Edited E", "Combined feature", "base"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("d").path))
        for file in ["a", "b", "c", "e"] { XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(file).path)) }
    }
    func testReorderRewordAndRejectInvalidOrDirtyPlans() async throws {
        for file in ["base", "a", "b"] { try await commitFile(file) }
        var plan = try await git.rebasePlan(at: path, upstream: "HEAD~2")
        plan.entries.swapAt(0, 1); plan.entries[0].action = .reword; plan.entries[0].message = "B first"
        var bad = plan; bad.entries[0].action = .squash
        do { try await git.validateRebasePlan(bad); XCTFail("Squash first") } catch {}
        try "dirty".write(to: directory.appendingPathComponent("untracked"), atomically: true, encoding: .utf8)
        do { _ = try await git.startRebase(at: path, plan: plan); XCTFail("Dirty worktree") } catch {}
        try FileManager.default.removeItem(at: directory.appendingPathComponent("untracked"))
        _ = try await git.startRebase(at: path, plan: plan)
        let history = try await git.history(at: path, revision: "HEAD")
        XCTAssertEqual(history.commits.map(\.subject), ["a", "B first", "base"])
    }
    func testConflictSkipAndAbort() async throws {
        try await commitFile("file", text: "one\n")
        try await commitFile("file", text: "two\n")
        try await commitFile("file", text: "three\n")
        var plan = try await git.rebasePlan(at: path, upstream: "HEAD~2")
        plan.entries.swapAt(0, 1)
        _ = try await git.startRebase(at: path, plan: plan)
        let state = try await git.operationState(at: path); XCTAssertEqual(state, .rebase)
        let changes = try await git.changes(at: path); XCTAssertTrue(changes.contains(where: \.conflicted))
        try await git.controlRebase(at: path, action: "abort")
        let restored = try await git.run(path, ["rev-parse", "HEAD"]).trimmingCharacters(in: .newlines)
        XCTAssertEqual(restored, plan.originalHead)
        _ = try await git.startRebase(at: path, plan: plan)
        try await git.controlRebase(at: path, action: "skip")
        let complete = try await git.operationState(at: path); XCTAssertEqual(complete, .idle)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("file")), "two\n")
    }
}
