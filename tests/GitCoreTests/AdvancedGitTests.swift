import XCTest
@testable import GitCore

final class AdvancedGitTests: XCTestCase {
    var directory: URL!
    var path: String { directory.path }
    let git = GitRepository()
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("citadel-advanced-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await git.run(path, ["init", "-b", "main"])
        try await git.run(path, ["config", "user.name", "Test"])
        try await git.run(path, ["config", "user.email", "test@example.com"])
        try await git.run(path, ["config", "commit.gpgsign", "false"])
    }
    override func tearDown() async throws { try FileManager.default.removeItem(at: directory) }
    func write(_ file: String, _ text: String) throws { try text.write(to: directory.appendingPathComponent(file), atomically: true, encoding: .utf8) }
    func commit(_ text: String) async throws { try await git.run(path, ["add", "."]); try await git.commit(at: path, message: text) }

    func testLargeDiffPagesAndPinnedHistory() async throws {
        try write("file.txt", "start\n"); try await commit("Initial")
        let first = try await git.history(at: path, revision: "HEAD", count: 1)
        try write("file.txt", (0..<20_000).map { "Line \($0) with enough content to exceed the old preview limit" }.joined(separator: "\n") + "\n")
        let document = try await git.diffDocument(at: path, file: "file.txt")
        var lines = 0, done = false, pages = 0
        while !done {
            let page = try await document.nextPage(count: 200)
            XCTAssertLessThanOrEqual(page.lines.count, 200)
            lines += page.lines.count; done = page.complete; pages += 1
        }
        XCTAssertGreaterThan(lines, 20_000); XCTAssertGreaterThan(pages, 90)
        try await commit("Next")
        let pinned = try await git.history(at: path, revision: first.tip, count: 1)
        XCTAssertEqual(pinned.commits.map(\.hash), first.commits.map(\.hash))
        let page = try await git.history(at: path, revision: "HEAD", count: 1)
        let older = try await git.history(at: path, revision: page.tip, offset: page.nextOffset!, count: 1)
        XCTAssertEqual(older.commits.first?.subject, "Initial")
        XCTAssertNil(older.nextOffset)
    }
    func testCancellationStopsGitHookAndPreservesRepository() async throws {
        try write("file.txt", "test\n"); try await git.stage(at: path, files: ["file.txt"])
        let hook = directory.appendingPathComponent(".git/hooks/pre-commit")
        try "#!/bin/sh\nsleep 30\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        let started = Date()
        let task = Task { try await git.commit(at: path, message: "Should cancel") }
        try await Task.sleep(nanoseconds: 200_000_000); task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("Unexpected: \(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        let changes = try await git.changes(at: path)
        XCTAssertEqual(changes.count, 1)
    }
    func testCloneInitializeAndStashes() async throws {
        let new = directory.appendingPathComponent("new repo")
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        try "keep".write(to: new.appendingPathComponent("existing.txt"), atomically: true, encoding: .utf8)
        // Initialization inside an existing repository is intentionally rejected.
        do { _ = try await git.initialize(at: new.path); XCTFail("Nested repository") } catch {}
        try write("file.txt", "base\n"); try await commit("Initial")
        let clone = directory.appendingPathComponent("clone")
        _ = try await git.clone(source: path, parent: path, name: "clone")
        XCTAssertTrue(FileManager.default.fileExists(atPath: clone.appendingPathComponent("file.txt").path))
        do { _ = try await git.clone(source: "https://user:secret@example.com/repo", parent: path, name: "bad"); XCTFail("Credentials") } catch {}
        try FileManager.default.removeItem(at: clone)
        try FileManager.default.removeItem(at: new)
        try write("file.txt", "stashed\n"); try write("untracked.txt", "new\n")
        try await git.createStash(at: path, message: "My stash", includeUntracked: true)
        let stashes = try await git.stashes(at: path)
        XCTAssertEqual(stashes.count, 1)
        let files = try await git.stashFiles(at: path, oid: stashes[0].oid)
        XCTAssertTrue(files.contains("untracked.txt"))
        let doc = try await git.stashDiff(at: path, oid: stashes[0].oid, file: "untracked.txt")
        let page = try await doc.nextPage()
        XCTAssertTrue(page.lines.contains { $0.text == "+new" })
        try await git.applyStash(at: path, oid: stashes[0].oid, pop: true)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("file.txt")), "stashed\n")
        let remaining = try await git.stashes(at: path); XCTAssertTrue(remaining.isEmpty)
    }
    func testStashPopConflictRetainsStash() async throws {
        try write("file.txt", "base\n"); try await commit("Initial")
        try write("file.txt", "stash\n")
        try await git.createStash(at: path, message: "conflict", includeUntracked: false)
        let stash = try await git.stashes(at: path)[0]
        try write("file.txt", "branch\n"); try await commit("Conflicting commit")
        do { try await git.applyStash(at: path, oid: stash.oid, pop: true); XCTFail("Expected conflict") } catch {}
        let retained = try await git.stashes(at: path)
        XCTAssertEqual(retained.first?.oid, stash.oid)
        let changes = try await git.changes(at: path)
        XCTAssertTrue(changes.contains(where: \.conflicted))
    }

}
