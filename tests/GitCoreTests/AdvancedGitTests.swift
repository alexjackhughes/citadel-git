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

    func testPartialLineStageUnstageAndStaleProtection() async throws {
        let file = "-literal [日本].txt"
        try write(file, "one\r\ntwo\r\nthree\r\n"); try await commit("Initial")
        let working = "one\r\ntwo changed\r\nthree\r\nfour\r\n"
        try write(file, working)
        let doc = try await git.diffDocument(at: path, file: file)
        let page = try await doc.nextPage()
        let added = page.lines.first { $0.text == "+four\r" }!
        try await git.applySelection(at: path, document: doc, selected: [added.id])
        let index = try await git.run(path, ["show", ":" + file])
        XCTAssertEqual(index, "one\r\ntwo\r\nthree\r\nfour\r\n")
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent(file)), working)
        do { try await git.applySelection(at: path, document: doc, selected: [added.id]); XCTFail("Stale snapshot") } catch {}
        let staged = try await git.diffDocument(at: path, file: file, staged: true)
        let stagedPage = try await staged.nextPage()
        let ids = Set(stagedPage.lines.filter { $0.kind == .addition || $0.kind == .deletion }.map(\.id))
        try await git.applySelection(at: path, document: staged, selected: ids)
        let cleanIndex = try await git.run(path, ["diff", "--cached"])
        XCTAssertEqual(cleanIndex, "")
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent(file)), working)
    }
    func testPartialNewFileAndIncompleteHunk() async throws {
        try write("base", "base\n"); try await commit("Initial")
        try write("new.txt", "first\nsecond")
        let doc = try await git.diffDocument(at: path, file: "new.txt")
        let page = try await doc.nextPage()
        let second = page.lines.first { $0.text == "+second" }!
        try await git.applySelection(at: path, document: doc, selected: [second.id])
        let index = try await git.run(path, ["show", ":new.txt"])
        XCTAssertEqual(index, "second")
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("new.txt")), "first\nsecond")
        try write("base", (0..<1000).map(String.init).joined(separator: "\n"))
        let incomplete = try await git.diffDocument(at: path, file: "base")
        let smallPage = try await incomplete.nextPage(count: 10)
        let chosen = smallPage.lines.first { $0.kind == .addition }!
        do { try await git.applySelection(at: path, document: incomplete, selected: [chosen.id]); XCTFail("Incomplete hunk") } catch {}
    }

    func makeConflict() async throws {
        try write("file.txt", "base\n"); try await commit("Initial")
        try await git.switchBranch(at: path, branch: "other", create: true)
        try write("file.txt", "incoming\n"); try await commit("Incoming")
        try await git.switchBranch(at: path, branch: "main")
        try write("file.txt", "current\n"); try await commit("Current")
        _ = try await git.run(path, ["merge", "other"], allowFailure: true)
    }
    func testConflictDraftSaveResolveAndExternalChange() async throws {
        try await makeConflict()
        let snapshot = try await git.conflict(at: path, file: "file.txt")
        XCTAssertTrue(snapshot.editable)
        XCTAssertEqual(snapshot.version(1)?.text, "base\n")
        XCTAssertEqual(snapshot.version(2)?.text, "current\n")
        XCTAssertEqual(snapshot.version(3)?.text, "incoming\n")
        XCTAssertEqual(ConflictBlock.parse(snapshot.result!).count, 1)
        do { try await git.markResolved(at: path, snapshot: snapshot); XCTFail("Markers remain") } catch {}
        try write("file.txt", "external edit\n")
        do { _ = try await git.saveConflict(at: path, snapshot: snapshot, result: "draft\n"); XCTFail("Stale source") } catch {}
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("file.txt")), "external edit\n")
        let fresh = try await git.conflict(at: path, file: "file.txt")
        let saved = try await git.saveConflict(at: path, snapshot: fresh, result: "resolved\n")
        let pending = try await git.changes(at: path); XCTAssertTrue(pending[0].conflicted)
        try await git.markResolved(at: path, snapshot: saved)
        let resolved = try await git.changes(at: path); XCTAssertFalse(resolved.contains(where: \.conflicted))
        let state = try await git.operationState(at: path); XCTAssertEqual(state, .merge)
    }
    func testBinaryConflictWholeVersionAndDiff3Parsing() async throws {
        let sample = "before\n<<<<<<< current\nA\n||||||| base\nB\n=======\nC\n>>>>>>> incoming\nafter\n"
        let blocks = ConflictBlock.parse(sample)
        XCTAssertEqual(blocks.count, 1); XCTAssertEqual(blocks[0].current, "A\n"); XCTAssertEqual(blocks[0].incoming, "C\n")
        try write("file.txt", "base\0"); try await commit("Initial")
        try await git.switchBranch(at: path, branch: "other", create: true)
        try write("file.txt", "incoming\0"); try await commit("Incoming")
        try await git.switchBranch(at: path, branch: "main")
        try write("file.txt", "current\0"); try await commit("Current")
        _ = try await git.run(path, ["merge", "other"], allowFailure: true)
        let snapshot = try await git.conflict(at: path, file: "file.txt")
        XCTAssertFalse(snapshot.editable)
        let chosen = try await git.chooseConflictVersion(at: path, snapshot: snapshot, stage: 3)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("file.txt")), Data("incoming\0".utf8))
        try await git.markResolved(at: path, snapshot: chosen)
    }

    func testTenThousandCommitPaginationWithoutDuplicates() async throws {
        var stream = ""
        for index in 0..<10_050 {
            let message = "Commit \(index)"
            stream += "commit refs/heads/main\nmark :\(index + 1)\ncommitter Test <test@example.com> \(1_600_000_000 + index) +0000\ndata \(message.utf8.count)\n\(message)\n"
            if index > 0 { stream += "from :\(index)\n" }
            stream += "\n"
        }
        stream += "done\n"
        try await git.run(path, ["fast-import", "--quiet"], input: Data(stream.utf8))
        var offset: Int? = 0, tip = "HEAD", seen = Set<String>(), count = 0
        while let start = offset {
            let page = try await git.history(at: path, revision: tip, offset: start)
            tip = page.tip; offset = page.nextOffset
            for commit in page.commits { XCTAssertTrue(seen.insert(commit.hash).inserted); count += 1 }
        }
        XCTAssertEqual(count, 10_050)
    }
    func testMultipleHunksAndExternalEditProtection() async throws {
        let original = (0..<40).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try write("file.txt", original); try await commit("Initial")
        let working = original.replacingOccurrences(of: "line 2\n", with: "replacement 2\n").replacingOccurrences(of: "line 35\n", with: "replacement 35\n")
        try write("file.txt", working)
        let doc = try await git.diffDocument(at: path, file: "file.txt")
        let page = try await doc.nextPage()
        XCTAssertEqual(page.hunks.count, 2)
        let ids = Set(page.lines.filter { $0.kind == .addition || $0.kind == .deletion }.map(\.id))
        try await git.applySelection(at: path, document: doc, selected: ids)
        let index = try await git.run(path, ["show", ":file.txt"]); XCTAssertEqual(index, working)
        let staged = try await git.diffDocument(at: path, file: "file.txt", staged: true)
        let stagedPage = try await staged.nextPage()
        let firstHunk = Set(stagedPage.hunks[0].lineIDs)
        try write("file.txt", working + "external\n")
        do { try await git.applySelection(at: path, document: staged, selected: firstHunk); XCTFail("External edit") } catch {}
        let untouchedIndex = try await git.run(path, ["show", ":file.txt"]); XCTAssertEqual(untouchedIndex, working)
    }
    func testInitializeStandalonePreservesExistingFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("citadel-init-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "keep".write(to: folder.appendingPathComponent("existing"), atomically: true, encoding: .utf8)
        _ = try await git.initialize(at: folder.path)
        let snapshot = try await git.snapshot(at: folder.path)
        XCTAssertEqual(snapshot.branch, "main"); XCTAssertTrue(snapshot.commits.isEmpty)
        XCTAssertEqual(snapshot.changes.first?.index, "?")
        let reopened = try await git.initialize(at: folder.path)
        XCTAssertEqual(URL(fileURLWithPath: reopened).resolvingSymlinksInPath().path, folder.resolvingSymlinksInPath().path)
    }

}
