import SwiftUI
import GitCore

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var branchName = ""

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 205, max: 260)
        } detail: {
            Group {
                if let snapshot = model.snapshot {
                    workspace(snapshot)
                } else if model.loading {
                    ProgressView("Opening repository…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    welcome
                }
            }
            .navigationTitle(model.selectedRepository.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Citadel")

            .toolbar { toolbar }
        }
        .tint(.accentColor)
        .sheet(isPresented: $model.showNewBranch) { branchSheet }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            Menu {
                ForEach(model.repositories, id: \.self) { path in
                    Button { model.selectRepository(path) } label: {
                        if path == model.selectedRepository { Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "checkmark") }
                        else { Text(URL(fileURLWithPath: path).lastPathComponent) }
                    }
                }
                Divider()
                Button("Add Repository…") { model.addRepository() }
                if let path = model.selectedRepository {
                    Button("Show in Finder") { model.revealRepository() }
                    Button("Remove from Workspace") { model.removeRepository(path) }
                }
            } label: {
                Label(model.selectedRepository.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Repositories", systemImage: "folder")
                    .font(.system(size: 12, weight: .semibold)).frame(maxWidth: .infinity, alignment: .leading)
            }.menuStyle(.borderlessButton).padding(14).disabled(model.busy)
            Divider()
            if let snapshot = model.snapshot {
                List(selection: Binding<String?>(get: { model.navigationSelection }, set: { if let value = $0 { model.navigate(value) } })) {
                    Section("Workspace") {
                        HStack {
                            Label("Working Copy", systemImage: "folder")
                            Spacer()
                            if !snapshot.changes.isEmpty { Text("\(snapshot.changes.count)").font(.caption).foregroundStyle(.secondary) }
                        }.tag("working")
                        Label("History", systemImage: "clock.arrow.circlepath").tag("history")
                    }
                    Section {
                        ForEach(snapshot.branches, id: \.self) { branch in
                            HStack(spacing: 6) {
                                Label(branch, systemImage: "arrow.triangle.branch").lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 2)
                                if branch == snapshot.branch { Text("HEAD").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary) }
                            }.tag("branch:" + branch)
                                .help("Browse \(branch)")
                                .contextMenu {
                                    Button("Check Out \(branch)") { model.branch(branch) }.disabled(branch == snapshot.branch || model.busy || model.loading)
                                    Button("New Branch…") { branchName = ""; model.showNewBranch = true }
                                }
                        }
                    } header: {
                        HStack {
                            Text("Branches")
                            Spacer()
                            Button { branchName = ""; model.showNewBranch = true } label: { Image(systemName: "plus") }
                                .buttonStyle(.borderless).help("New branch")
                        }
                    }
                }.listStyle(.sidebar).disabled(model.busy)
            } else { Spacer() }
            Divider()
            HStack {
                Button { model.addRepository() } label: { Label("Add Repository", systemImage: "plus") }
                    .buttonStyle(.borderless).disabled(model.busy)
                Spacer()
            }.padding(.horizontal, 12).padding(.vertical, 10)
        }
    }

    private var welcome: some View {
        VStack(spacing: 12) {
            Image(nsImage: Bundle.main.url(forResource: "CitadelLighthouse", withExtension: "icns").flatMap { NSImage(contentsOf: $0) } ?? NSApplication.shared.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("Citadel").font(.system(size: 26, weight: .semibold))
            Text("Your repositories. Every change in view.")
                .font(.system(size: 14)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(4)
            Button("Add a Repository…") { model.addRepository() }.controlSize(.regular).buttonStyle(.borderedProminent).padding(.top, 8)
            Text("Add a local Git repository to get started.").font(.caption).foregroundStyle(.tertiary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func workspace(_ snapshot: RepositorySnapshot) -> some View {
        VStack(spacing: 0) {
            if model.operationState != .idle {
                HStack {
                    Label("\(model.operationState.rawValue.capitalized) in progress", systemImage: "exclamationmark.triangle")
                    Text("Resolve conflicts before continuing.").foregroundStyle(.secondary)
                    Spacer()
                }.font(.callout).padding(10).background(Color.orange.opacity(0.12))
                Divider()
            }
            if model.tab == .history { HistoryView() } else { ChangesView() }
            Divider()
            HStack(spacing: 7) {
                if model.busy || model.loading { ProgressView().controlSize(.mini) }

                Text(model.busy ? model.status : (model.snapshot?.changes.isEmpty == true ? "Working tree clean" : "\(model.snapshot?.changes.count ?? 0) uncommitted changes")).lineLimit(1)
                if model.busy {
                    if let started = model.operationStarted { Text(started, style: .relative) }
                    Text(model.operationProgress).lineLimit(1).foregroundStyle(.secondary)
                    Button("Cancel") { model.cancelOperation() }.controlSize(.small)
                }
                Spacer()
                Image(systemName: "arrow.triangle.branch")
                Text(snapshot.branch)
                if snapshot.ahead > 0 { Text("↑ \(snapshot.ahead)") }
                if snapshot.behind > 0 { Text("↓ \(snapshot.behind)") }
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 5)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            if model.snapshot != nil {
                Text(model.tab == .changes ? "Working Copy" : (model.historyBranch ?? "History"))
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if let snapshot = model.snapshot {
                Button { Task { await model.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Refresh repository (⌘R)").disabled(model.busy || model.loading)
                // Remotes are optional. Local-only repositories have no sync controls.
                if !snapshot.remotes.isEmpty {
                    Button { model.sync("fetch") } label: { Label("Fetch", systemImage: "arrow.triangle.2.circlepath") }.help("Fetch from remotes").disabled(model.busy || model.loading)
                    Button { model.sync("pull") } label: { Label("Pull", systemImage: "arrow.down") }.help("Pull, fast-forward only").disabled(model.busy || model.loading || snapshot.upstream.isEmpty)
                    Button { model.sync("push") } label: { Label("Push", systemImage: "arrow.up") }.help("Push commits").disabled(model.busy || model.loading)
                }
            }
            Button { model.addRepository() } label: { Label("Add Repository", systemImage: "folder.badge.plus") }.help("Add repository (⌘O)").disabled(model.busy)
        }
    }

    private var branchSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("New Branch", systemImage: "arrow.triangle.branch").font(.title2.weight(.semibold))
            Text("Create a branch from the current HEAD and switch to it.").foregroundStyle(.secondary)
            TextField("feature/my-next-idea", text: $branchName).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { model.showNewBranch = false }.keyboardShortcut(.cancelAction)
                Button("Create Branch") { model.showNewBranch = false; model.branch(branchName.trimmingCharacters(in: .whitespaces), create: true) }
                    .keyboardShortcut(.defaultAction).disabled(branchName.trimmingCharacters(in: .whitespaces).isEmpty || model.busy)
            }
        }.padding(24).frame(width: 420)
    }
}
