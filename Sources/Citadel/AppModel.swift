import AppKit
import SwiftUI
import GitCore

enum WorkspaceTab: String, CaseIterable { case history = "History", changes = "Working Copy" }

@MainActor
final class AppModel: ObservableObject {
    let git = GitRepository()
    // Preview reads do not queue behind a complete repository/history refresh.
    private let previewGit = GitRepository()
    private var workingPreviewTask: Task<Void, Never>?
    private var historyPreviewTask: Task<Void, Never>?

    @Published var repositories: [String] = UserDefaults.standard.stringArray(forKey: "repositories") ?? []
    @Published var selectedRepository: String?
    @Published var snapshot: RepositorySnapshot?
    @Published var tab: WorkspaceTab = .changes
    @Published var historyBranch: String?
    @Published var selectedCommit: String?
    @Published var detail: CommitDetail?
    @Published var selectedHistoryFile: String?
    @Published var selectedFile: String?
    @Published var selectedFileStaged = false
    @Published var diff = ""
    @Published var historyDiff = ""
    @Published var message = ""
    @Published var search = ""
    @Published var busy = false
    @Published var loading = false
    @Published var error: String?
    @Published var status = "Everything stays on your Mac"
    @Published var showNewBranch = false
    @Published var commitLimit = 300
    private var refreshID = UUID()
    private var diffID = UUID()
    private var historyDiffID = UUID()
    private var drafts: [String: String] = [:]

    var navigationSelection: String {
        if tab == .changes { return "working" }
        return historyBranch.map { "branch:" + $0 } ?? "history"
    }
    func navigate(_ selection: String) {
        guard !busy else { return }
        if selection == "working" { tab = .changes; return }
        let branch = selection.hasPrefix("branch:") ? String(selection.dropFirst(7)) : nil
        tab = .history
        guard branch != historyBranch else { return }
        historyBranch = branch; commitLimit = 300; search = ""
        selectedCommit = nil; detail = nil; selectedHistoryFile = nil; historyDiff = ""
        Task { await refresh() }
    }

    var currentCommit: GitCommit? { snapshot?.commits.first { $0.hash == selectedCommit } }
    var stagedFiles: [ChangedFile] { snapshot?.changes.filter(\.staged) ?? [] }
    var unstagedFiles: [ChangedFile] { snapshot?.changes.filter(\.unstaged) ?? [] }
    var canCommit: Bool { !busy && !loading && !stagedFiles.isEmpty && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var filteredCommits: [GitCommit] {
        let commits = snapshot?.commits ?? []
        guard !search.isEmpty else { return commits }
        return commits.filter { "\($0.subject) \($0.author) \($0.hash) \($0.refs)".localizedCaseInsensitiveContains(search) }
    }

    init() {
        let previous = UserDefaults.standard.string(forKey: "selectedRepository")
        let initial = repositories.first { $0 == previous } ?? repositories.first
        if let initial { selectRepository(initial) }
    }

    func addRepository() {
        let panel = NSOpenPanel()
        panel.title = "Add a Git Repository"
        panel.message = "Choose a folder containing an existing Git repository."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add Repository"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task {
            for url in urls {
                do {
                    let root = try await git.root(at: url.path)
                    if !repositories.contains(root) { repositories.append(root) }
                    persist()
                    selectRepository(root)
                } catch { self.error = error.localizedDescription }
            }
        }
    }

    func persist() { UserDefaults.standard.set(repositories, forKey: "repositories") }

    func removeRepository(_ path: String) {
        guard !busy else { return }
        repositories.removeAll { $0 == path }; persist()
        if selectedRepository == path {
            if let next = repositories.first { selectRepository(next) }
            else { selectedRepository = nil; snapshot = nil; refreshID = UUID(); loading = false }
        }
    }

    func selectRepository(_ path: String) {
        guard !busy, path != selectedRepository || snapshot == nil else { return }
        if let previous = selectedRepository { drafts[previous] = message }
        workingPreviewTask?.cancel(); historyPreviewTask?.cancel()
        diffID = UUID(); historyDiffID = UUID()
        selectedRepository = path
        UserDefaults.standard.set(path, forKey: "selectedRepository")
        snapshot = nil; selectedCommit = nil; detail = nil; selectedFile = nil
        selectedHistoryFile = nil; diff = ""; historyDiff = ""; search = ""
        message = drafts[path] ?? ""; commitLimit = 300; historyBranch = nil; tab = .changes
        Task { await refresh() }
    }

    func refresh() async {
        guard let path = selectedRepository else { return }
        let request = UUID(); refreshID = request; loading = true
        defer { if refreshID == request { loading = false } }
        do {
            let result = try await git.snapshot(at: path, limit: commitLimit, historyBranch: historyBranch)
            guard refreshID == request, selectedRepository == path else { return }
            snapshot = result
            if !result.commits.contains(where: { $0.hash == selectedCommit }) {
                selectedCommit = result.commits.first?.hash
                await loadCommit()
            }
            if let selectedFile {
                if let file = result.changes.first(where: { $0.path == selectedFile }) {
                    await previewFile(file.path, staged: selectedFileStaged ? file.staged : !file.unstaged)
                } else { self.selectedFile = nil; diff = "" }
            }
        } catch { if refreshID == request { self.error = error.localizedDescription } }
    }

    func loadCommit() async {
        guard let path = selectedRepository, let hash = selectedCommit else { detail = nil; return }
        detail = nil; selectedHistoryFile = nil; historyDiff = ""; historyDiffID = UUID()
        do {
            let result = try await git.detail(at: path, commit: hash)
            guard path == selectedRepository, hash == selectedCommit else { return }
            detail = result
            if let first = result.files.first { await previewHistoryFile(first) }
        } catch { self.error = error.localizedDescription }
    }

    func previewHistoryFile(_ file: String) async {
        guard let path = selectedRepository, let hash = selectedCommit else { return }
        historyPreviewTask?.cancel()
        let request = UUID(); historyDiffID = request; selectedHistoryFile = file; historyDiff = ""
        let task = Task {
            do {
                try Task.checkCancellation()
                let result = try await previewGit.diff(at: path, file: file, commit: hash)
                guard !Task.isCancelled, request == historyDiffID, path == selectedRepository, hash == selectedCommit else { return }
                historyDiff = result
            } catch is CancellationError { }
            catch { if request == historyDiffID, path == selectedRepository, hash == selectedCommit { self.error = error.localizedDescription } }
        }
        historyPreviewTask = task
        await task.value
    }

    func previewFile(_ file: String, staged: Bool) async {
        guard let path = selectedRepository else { return }
        workingPreviewTask?.cancel()
        let request = UUID(); diffID = request
        selectedFile = file; selectedFileStaged = staged; diff = ""
        let task = Task {
            do {
                try Task.checkCancellation()
                let result = try await previewGit.diff(at: path, file: file, staged: staged)
                guard !Task.isCancelled, request == diffID, path == selectedRepository else { return }
                diff = result
            } catch is CancellationError { }
            catch { if request == diffID, path == selectedRepository { self.error = error.localizedDescription } }
        }
        workingPreviewTask = task
        await task.value
    }

    func perform(_ title: String, operation: @escaping (GitRepository, String) async throws -> Void) {
        guard let path = selectedRepository, !busy, !loading else { return }
        busy = true; status = title + "…"
        Task {
            do {
                try await operation(git, path)
                status = title + " complete"
                await refresh()
            } catch {
                self.error = error.localizedDescription
                status = "\(title) did not complete"
                await refresh()
            }
            busy = false
        }
    }

    func stage(_ file: ChangedFile) { perform("Stage file") { git, path in try await git.stage(at: path, files: file.index == "R" ? [file.path] : file.paths) } }
    func unstage(_ file: ChangedFile) { perform("Unstage file") { git, path in try await git.unstage(at: path, files: file.paths) } }
    func toggleStaging(_ selection: Set<String>) {
        let files = snapshot?.changes.filter { selection.contains($0.path) } ?? []
        guard !files.isEmpty else { return }
        let shouldStage = files.contains(where: \.unstaged)
        let paths = Array(Set(files.filter { shouldStage ? $0.unstaged : $0.staged }.flatMap {
            shouldStage && $0.index == "R" ? [$0.path] : $0.paths
        }))
        guard !paths.isEmpty else { return }
        perform(shouldStage ? "Stage selection" : "Unstage selection") { git, path in
            if shouldStage { try await git.stage(at: path, files: paths) }
            else { try await git.unstage(at: path, files: paths) }
        }
    }
    func stageAll() {
        let files = Array(Set(unstagedFiles.flatMap { $0.index == "R" ? [$0.path] : $0.paths }))
        guard !files.isEmpty else { return }
        perform("Stage all") { git, path in try await git.stage(at: path, files: files) }
    }
    func unstageAll() {
        let files = Array(Set(stagedFiles.flatMap(\.paths)))
        guard !files.isEmpty else { return }
        perform("Unstage all") { git, path in try await git.unstage(at: path, files: files) }
    }
    func commit() {
        guard canCommit else { return }
        let text = message
        perform("Commit") { git, path in
            try await git.commit(at: path, message: text)
            await MainActor.run { self.message = ""; self.drafts[path] = "" }
        }
    }
    func branch(_ name: String, create: Bool = false) {
        perform(create ? "Create branch" : "Switch branch") { git, path in
            try await git.switchBranch(at: path, branch: name, create: create)
            await MainActor.run { self.historyBranch = name; self.selectedCommit = nil }
        }
    }
    func sync(_ operation: String) {
        perform(operation.capitalized) { git, path in try await git.sync(at: path, operation: operation) }
    }
    func revealRepository() {
        if let path = selectedRepository { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path) }
    }
}
