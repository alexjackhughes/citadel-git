import AppKit
import SwiftUI
import GitCore

enum WorkspaceTab: String, CaseIterable { case history = "History", changes = "Working Copy", stashes = "Stashes" }

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
    @Published var diffDocument: DiffDocument?
    @Published var historyDocument: DiffDocument?
    @Published var historyDiff = ""
    @Published var message = ""
    @Published var search = ""
    @Published var busy = false
    @Published var loading = false
    @Published var error: String?
    @Published var status = "Everything stays on your Mac"
    @Published var creationMode: CreationMode?
    @Published var stashes: [GitStash] = []
    @Published var showCreateStash = false
    @Published var showRebase = false
    @Published var rebaseUpstream: String?
    @Published var rebaseEditing = false
    @Published var rebaseMessage = ""
    @Published var lastRebaseBackup: String?
    @Published var showNewBranch = false
    @Published var commitLimit = 300
    @Published var commits: [GitCommit] = []
    @Published var searchResults: [GitCommit] = []
    @Published var searching = false
    @Published var loadingMore = false
    @Published var nextHistoryOffset: Int?
    @Published var operationState: RepositoryOperationState = .idle
    @Published var operationStarted: Date?
    @Published var operationProgress = ""
    private var historyTip: String?
    var operationTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var historyGeneration = UUID()

    private var refreshID = UUID()
    private var diffID = UUID()
    private var historyDiffID = UUID()
    private var drafts: [String: String] = [:]

    var navigationSelection: String {
        if tab == .stashes { return "stashes" }
        if tab == .changes { return "working" }
        return historyBranch.map { "branch:" + $0 } ?? "history"
    }
    func navigate(_ selection: String) {
        guard !busy else { return }
        if selection == "stashes" { tab = .stashes; return }
        if selection == "working" { tab = .changes; return }
        let branch = selection.hasPrefix("branch:") ? String(selection.dropFirst(7)) : nil
        tab = .history
        guard branch != historyBranch else { return }
        historyBranch = branch; commitLimit = 300; search = ""
        selectedCommit = nil; detail = nil; selectedHistoryFile = nil; historyDiff = ""
        Task { await refresh() }
    }

    var currentCommit: GitCommit? { (commits + searchResults).first { $0.hash == selectedCommit } }
    var stagedFiles: [ChangedFile] { snapshot?.changes.filter(\.staged) ?? [] }
    var unstagedFiles: [ChangedFile] { snapshot?.changes.filter(\.unstaged) ?? [] }
    var canCommit: Bool { !busy && !loading && !stagedFiles.isEmpty && !(snapshot?.changes.contains(where: \.conflicted) ?? false) && operationState != .rebase && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var filteredCommits: [GitCommit] { search.isEmpty ? commits : searchResults }

    func loadMoreHistory() async {
        guard !loadingMore, let offset = nextHistoryOffset, let tip = historyTip, let path = selectedRepository else { return }
        let generation = historyGeneration
        loadingMore = true
        defer { if generation == historyGeneration { loadingMore = false } }
        do {
            let page = try await previewGit.history(at: path, revision: tip, offset: offset)
            guard generation == historyGeneration, path == selectedRepository else { return }
            commits += page.commits; nextHistoryOffset = page.nextOffset
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }

    func searchHistory() {
        searchTask?.cancel(); searchResults = []
        guard !search.isEmpty, let tip = historyTip, let path = selectedRepository else { searching = false; return }
        let query = search, generation = historyGeneration
        searching = true
        searchTask = Task {
            defer { if query == search, generation == historyGeneration { searching = false } }
            do {
                try await Task.sleep(nanoseconds: 200_000_000)
                var offset: Int? = 0
                while let start = offset {
                    try Task.checkCancellation()
                    let page = try await previewGit.history(at: path, revision: tip, offset: start)
                    guard !Task.isCancelled, query == search, generation == historyGeneration else { return }
                    searchResults += page.commits.filter { "\($0.subject) \($0.author) \($0.hash) \($0.refs)".localizedCaseInsensitiveContains(query) }
                    offset = page.nextOffset
                }
            } catch is CancellationError {} catch { if query == search { self.error = error.localizedDescription } }
        }
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

    func createRepository(mode: CreationMode, source: String, folder: String, name: String, branch: String) {
        guard !busy else { return }
        busy = true; status = mode == .clone ? "Cloning…" : "Initializing…"; operationStarted = Date()
        operationTask = Task { [self] in
            do {
                let path = try await GitOperation.$onEvent.withValue({ event in
                    if case let .output(text) = event { Task { @MainActor in self.operationProgress = String(text.suffix(500)) } }
                }) {
                    if mode == .clone { return try await git.clone(source: source, parent: folder, name: name) }
                    return try await git.initialize(at: folder, branch: branch)
                }
                if !repositories.contains(path) { repositories.append(path); persist() }
                busy = false; creationMode = nil; selectRepository(path)
            } catch is CancellationError { status = "Cancelled. Any partial destination is preserved." }
            catch { self.error = error.localizedDescription }
            busy = false; operationStarted = nil; operationProgress = ""; operationTask = nil
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
        lastRebaseBackup = nil
        selectedRepository = path
        UserDefaults.standard.set(path, forKey: "selectedRepository")
        historyGeneration = UUID(); searchTask?.cancel(); commits = []; nextHistoryOffset = nil; historyTip = nil
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
            operationState = try await git.operationState(at: path)
            stashes = try await git.stashes(at: path)
            if operationState == .rebase {
                let state = try await git.rebaseStatus(at: path)
                rebaseEditing = state.editing; rebaseMessage = state.message; lastRebaseBackup = state.backupRef
            } else { rebaseEditing = false }
            historyGeneration = UUID(); searchTask?.cancel(); loadingMore = false
            if let tip = result.commits.first?.hash {
                let page = try await previewGit.history(at: path, revision: tip)
                guard refreshID == request, selectedRepository == path else { return }
                commits = page.commits; historyTip = page.tip; nextHistoryOffset = page.nextOffset
            } else { commits = []; historyTip = nil; nextHistoryOffset = nil }
            searchHistory()
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
        let request = UUID(); historyDiffID = request; selectedHistoryFile = file; historyDiff = ""; historyDocument = nil
        let task = Task {
            do {
                try Task.checkCancellation()
                let result = try await previewGit.diffDocument(at: path, file: file, commit: hash)
                guard !Task.isCancelled, request == historyDiffID, path == selectedRepository, hash == selectedCommit else { return }
                historyDocument = result
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
        selectedFile = file; selectedFileStaged = staged; diff = ""; diffDocument = nil
        let task = Task {
            do {
                try Task.checkCancellation()
                let result = try await previewGit.diffDocument(at: path, file: file, staged: staged)
                guard !Task.isCancelled, request == diffID, path == selectedRepository else { return }
                diffDocument = result
            } catch is CancellationError { }
            catch { if request == diffID, path == selectedRepository { self.error = error.localizedDescription } }
        }
        workingPreviewTask = task
        await task.value
    }

    func perform(_ title: String, operation: @escaping (GitRepository, String) async throws -> Void) {
        guard let path = selectedRepository, !busy, !loading else { return }
        busy = true; status = title + "…"; operationStarted = Date(); operationProgress = ""
        operationTask = Task { [self] in
            do {
                try await GitOperation.$onEvent.withValue({ [weak self] event in
                    if case let .output(text) = event { Task { @MainActor in self?.operationProgress = String(text.suffix(300)).trimmingCharacters(in: .whitespacesAndNewlines) } }
                }) { try await operation(git, path) }
                status = title + " complete"
            } catch is CancellationError { status = title + " cancelled" }
            catch { self.error = error.localizedDescription; status = "\(title) did not complete" }
            // A cancelled task cannot run the reconciliation commands.
            await Task {
                await self.refresh()
                if let conflict = self.snapshot?.changes.first(where: \.conflicted) {
                    self.tab = .changes
                    await self.previewFile(conflict.path, staged: false)
                }
            }.value
            busy = false; operationStarted = nil; operationProgress = ""; operationTask = nil
        }
    }
    func cancelOperation() { operationTask?.cancel() }

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
