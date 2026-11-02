import XCTest
@testable import GitCore

final class GitRepositoryTests: XCTestCase {
    var directory: URL!
    var path: String { directory.path }
    let git = GitRepository()

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("citadel-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await git.run(path, ["init", "-b", "main"])
        try await git.run(path, ["config", "user.name", "Citadel Tests"])
        try await git.run(path, ["config", "user.email", "test@example.com"])
        try await git.run(path, ["config", "commit.gpgsign", "false"])
    }
    override func tearDown() async throws { try FileManager.default.removeItem(at: directory) }
    func write(_ file: String, _ content: String) throws { try content.write(to: directory.appendingPathComponent(file), atomically: true, encoding: .utf8) }
    func firstCommit() async throws {
        try write("hello.txt", "hello\n")
        try await git.stage(at: path, files: ["hello.txt"])
        try await git.commit(at: path, message: "Initial commit\n\nA longer description.")
    }

    func testUnbornRepositoryAndFirstCommit() async throws {
        let empty = try await git.snapshot(at: path)
        XCTAssertEqual(empty.branch, "main")
        XCTAssertTrue(empty.commits.isEmpty)
        try write("hello.txt", "hello\n")
        let untracked = try await git.diff(at: path, file: "hello.txt")
        XCTAssertTrue(untracked.contains("+hello"))
        try await git.stage(at: path, files: ["hello.txt"])
        try await git.unstage(at: path, files: ["hello.txt"])
        let changes = try await git.changes(at: path)
        XCTAssertFalse(changes[0].staged)
        try await firstCommit()
        let snapshot = try await git.snapshot(at: path)
        XCTAssertEqual(snapshot.commits.count, 1)
        XCTAssertTrue(snapshot.changes.isEmpty)
        let detail = try await git.detail(at: path, commit: snapshot.commits[0].hash)
        XCTAssertEqual(detail.files, ["hello.txt"])
        XCTAssertTrue(detail.message.contains("A longer description."))
        let diff = try await git.diff(at: path, file: "hello.txt", commit: snapshot.commits[0].hash)
        XCTAssertTrue(diff.contains("+hello"))
    }

    func testPartialStageCommitAndUnstage() async throws {
        try await firstCommit()
        try write("hello.txt", "hello\nfirst\n")
        try await git.stage(at: path, files: ["hello.txt"])
        try write("hello.txt", "hello\nfirst\nsecond\n")
        let changes = try await git.changes(at: path)
        XCTAssertTrue(changes[0].staged && changes[0].unstaged)
        let staged = try await git.diff(at: path, file: "hello.txt", staged: true)
        XCTAssertFalse(staged.contains("+second"))
        try await git.commit(at: path, message: "First only")
        let unstaged = try await git.diff(at: path, file: "hello.txt")
        XCTAssertTrue(unstaged.contains("+second"))
        try await git.stage(at: path, files: ["hello.txt"])
        try await git.unstage(at: path, files: ["hello.txt"])
        let final = try await git.changes(at: path)
        XCTAssertFalse(final[0].staged)
    }

    func testPathScopedPreviewsHandleUntrackedEmptyBinaryAndStagedFiles() async throws {
        try await firstCommit()
        try write("new [file].txt", "new line\n")
        try write("empty.txt", "")
        try Data([0, 1, 2]).write(to: directory.appendingPathComponent("binary.dat"))
        let untracked = try await git.diff(at: path, file: "new [file].txt")
        XCTAssertEqual(untracked, "+new line")
        let empty = try await git.diff(at: path, file: "empty.txt")
        XCTAssertEqual(empty, "")
        let binary = try await git.diff(at: path, file: "binary.dat")
        XCTAssertTrue(binary.contains("Binary file"))
        try await git.stage(at: path, files: ["new [file].txt"])
        let stagedOnly = try await git.diff(at: path, file: "new [file].txt")
        XCTAssertEqual(stagedOnly, "")
        let staged = try await git.diff(at: path, file: "new [file].txt", staged: true)
        XCTAssertTrue(staged.contains("+new line"))
        try write("new [file].txt", "new line\nsecond line\n")
        let updated = try await git.diff(at: path, file: "new [file].txt")
        XCTAssertTrue(updated.contains("+second line"))
    }

    func testBranchesRenamesAndLiteralPaths() async throws {
        try await firstCommit()
        try await git.switchBranch(at: path, branch: "feature/test", create: true)
        let branch = try await git.snapshot(at: path)
        XCTAssertEqual(branch.branch, "feature/test")
        try await git.switchBranch(at: path, branch: "main")
        try await git.run(path, ["mv", "hello.txt", "hello world.txt"])
        let rename = try await git.changes(at: path)
        XCTAssertEqual(rename[0].originalPath, "hello.txt")
        XCTAssertEqual(rename[0].path, "hello world.txt")
        try await git.unstage(at: path, files: rename[0].paths)
        try write("[test].txt", "literal\n")
        try write("t.txt", "do not stage\n")
        try await git.stage(at: path, files: ["[test].txt"])
        let files = try await git.changes(at: path)
        XCTAssertTrue(files.first { $0.path == "[test].txt" }!.staged)
        XCTAssertFalse(files.first { $0.path == "t.txt" }!.staged)
    }

    func testLocalRemoteRoundTrip() async throws {
        try await firstCommit()
        let remote = directory.appendingPathComponent("remote.git")
        try await git.run(path, ["init", "--bare", remote.path])
        try await git.run(path, ["remote", "add", "origin", remote.path])
        try await git.run(path, ["push", "-u", "origin", "main"])
        try write("hello.txt", "updated\n")
        try await git.stage(at: path, files: ["hello.txt"])
        try await git.commit(at: path, message: "Update")
        let before = try await git.snapshot(at: path)
        XCTAssertEqual(before.ahead, 1)
        try await git.sync(at: path, operation: "push")
        try await git.sync(at: path, operation: "fetch")
        try await git.sync(at: path, operation: "pull")
        let after = try await git.snapshot(at: path)
        XCTAssertEqual(after.ahead, 0)
        XCTAssertEqual(after.behind, 0)
    }

    func testPathValidation() async throws {
        do { try await git.stage(at: path, files: ["../outside"]); XCTFail("Traversal must fail") } catch {}
        do { _ = try await git.detail(at: path, commit: "--all"); XCTFail("Invalid revision must fail") } catch {}
        do { try await git.switchBranch(at: path, branch: "--orphan"); XCTFail("Option must fail") } catch {}
    }

    func testMergeDetailsAgainstFirstParent() async throws {
        try await firstCommit()
        try await git.switchBranch(at: path, branch: "feature", create: true)
        try write("feature.txt", "branch work\n")
        try await git.stage(at: path, files: ["feature.txt"])
        try await git.commit(at: path, message: "Feature")
        try await git.switchBranch(at: path, branch: "main")
        try await git.run(path, ["merge", "--no-ff", "feature", "-m", "Merge feature"])
        let snapshot = try await git.snapshot(at: path)
        XCTAssertEqual(snapshot.commits[0].parents.count, 2)
        let detail = try await git.detail(at: path, commit: snapshot.commits[0].hash)
        XCTAssertTrue(detail.files.contains("feature.txt"))
        let diff = try await git.diff(at: path, file: "feature.txt", commit: snapshot.commits[0].hash)
        XCTAssertTrue(diff.contains("+branch work"))
    }
    func testBrowsingBranchDoesNotCheckoutOrChangeWorkingCopy() async throws {
        try await firstCommit()
        try await git.switchBranch(at: path, branch: "feature/sidebar", create: true)
        try write("feature.txt", "Only on the feature branch\n")
        try await git.stage(at: path, files: ["feature.txt"])
        try await git.commit(at: path, message: "Feature-only commit")
        try await git.switchBranch(at: path, branch: "main")
        try write("hello.txt", "Uncommitted work must remain\n")
        let browsed = try await git.snapshot(at: path, historyBranch: "feature/sidebar")
        XCTAssertEqual(browsed.branch, "main")
        XCTAssertEqual(browsed.commits.first?.subject, "Feature-only commit")
        XCTAssertEqual(browsed.changes.first?.path, "hello.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("feature.txt").path))
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("hello.txt")), "Uncommitted work must remain\n")
        let current = try await git.snapshot(at: path)
        XCTAssertEqual(current.commits.first?.subject, "Initial commit")
        do {
            _ = try await git.snapshot(at: path, historyBranch: "--all")
            XCTFail("Unknown branch should be rejected")
        } catch {}
    }

    func testBranchOrderingPinsMainAndUsesCreationRatherThanLatestCommit() async throws {
        try await firstCommit()
        try await git.run(path, ["branch", "a-older"])
        try await git.run(path, ["branch", "z-newer"])
        // Give real creation entries deterministic dates, independent of clock resolution.
        for (name, timestamp) in [("a-older", "1600000000"), ("z-newer", "1700000000")] {
            let log = directory.appendingPathComponent(".git/logs/refs/heads/" + name)
            let contents = try String(contentsOf: log)
            let edited = contents.replacingOccurrences(of: #"> [0-9]+ [+-][0-9]{4}\t"#, with: "> " + timestamp + " +0000\t", options: .regularExpression)
            try edited.write(to: log, atomically: true, encoding: .utf8)
        }
        try await git.switchBranch(at: path, branch: "a-older")
        try write("new.txt", "A recent commit on the older branch\n")
        try await git.stage(at: path, files: ["new.txt"])
        try await git.commit(at: path, message: "Recent activity must not reorder creation dates")
        let snapshot = try await git.snapshot(at: path)
        XCTAssertEqual(snapshot.branches, ["main", "z-newer", "a-older"])
        // Expired or disabled reflogs must still leave every branch available.
        try FileManager.default.removeItem(at: directory.appendingPathComponent(".git/logs/refs/heads/a-older"))
        let fallback = try await git.snapshot(at: path)
        XCTAssertEqual(fallback.branches, ["main", "a-older", "z-newer"])
    }

}
