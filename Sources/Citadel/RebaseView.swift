import SwiftUI
import GitCore

struct RebasePlanView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var upstream = ""
    @State private var plan: RebasePlan?
    @State private var selected: String?
    @State private var loading = false
    @State private var error: String?
    @State private var confirming = false
    @State private var stashSheet = false
    private var dirty: Bool { model.snapshot?.changes.isEmpty == false }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Interactive Rebase").font(.title2.bold())
            HStack {
                TextField("Upstream to exclude (blank includes root)", text: $upstream).textFieldStyle(.roundedBorder)
                Button("Load Commits") { Task { await load() } }.disabled(loading)
            }
            Text("Oldest first. Reorder with drag handles or Move Up/Down. Merge commits are not supported.").font(.caption).foregroundStyle(.secondary)
            if dirty {
                HStack { Label("Commit or stash your changes before starting.", systemImage: "exclamationmark.triangle"); Spacer(); Button("Stash Changes…") { stashSheet = true } }.foregroundStyle(.orange)
            }
            if let plan {
                Text("Branch: \(plan.branch) · \(plan.entries.count) commits").font(.headline)
                List(selection: $selected) {
                    ForEach(plan.entries) { entry in
                        HStack {
                            Picker("Action", selection: actionBinding(entry.oid)) { ForEach(RebaseAction.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }.frame(width: 115)
                            Text(String(entry.oid.prefix(8))).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                            VStack(alignment: .leading) {
                                Text(entry.subject).lineLimit(1)
                                if !entry.remoteRefs.isEmpty { Text("On remote: " + entry.remoteRefs.joined(separator: ", ")).font(.caption).foregroundStyle(.orange).lineLimit(1) }
                            }
                        }.tag(entry.oid)
                    }.onMove { indexes, destination in self.plan?.entries.move(fromOffsets: indexes, toOffset: destination) }
                }.frame(minHeight: 220)
                HStack {
                    Button("Move Up") { move(-1) }.disabled(selected == nil)
                    Button("Move Down") { move(1) }.disabled(selected == nil)
                    Spacer()
                }
                if let selected, let entry = plan.entries.first(where: { $0.oid == selected }), [.reword, .squash].contains(entry.action) {
                    Text(entry.action == .squash ? "Resulting combined commit message" : "Replacement commit message").font(.caption.bold())
                    TextEditor(text: messageBinding(selected)).font(.system(size: 12)).frame(height: 85).overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                }
            } else if loading { ProgressView().frame(maxWidth: .infinity, minHeight: 200) }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            Text("A local backup reference is retained. Rewritten commits are never pushed automatically.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer(); Button("Cancel") { dismiss() }
                Button("Review and Start…") {
                    guard let plan else { return }
                    Task {
                        do { try await model.git.validateRebasePlan(plan); confirming = true }
                        catch { self.error = error.localizedDescription }
                    }
                }.buttonStyle(.borderedProminent).disabled(plan == nil || loading || dirty || model.busy || model.operationState != .idle)
            }
        }.padding(24).frame(width: 730, height: 620)
            .task { upstream = model.rebaseUpstream ?? ""; await load() }
            .sheet(isPresented: $stashSheet) { CreateStashView() }
            .confirmationDialog("Rewrite these commits?", isPresented: $confirming) {
                Button("Start Rebase") {
                    guard let plan else { return }; dismiss()
                    model.perform("Rebase") { git, path in
                        let backup = try await git.startRebase(at: path, plan: plan)
                        await MainActor.run { model.lastRebaseBackup = backup }
                    }
                }
            } message: {
                Text("This rewrites the selected local branch. \(plan?.entries.filter { !$0.remoteRefs.isEmpty }.count ?? 0) selected commits are reachable from known remote-tracking references. A backup ref will preserve the original tip.")
            }
    }
    private func load() async {
        guard let path = model.selectedRepository else { return }
        loading = true; error = nil; plan = nil
        defer { loading = false }
        do { let value = try await model.git.rebasePlan(at: path, upstream: upstream); if !Task.isCancelled { plan = value; selected = value.entries.first?.oid } }
        catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    private func actionBinding(_ oid: String) -> Binding<RebaseAction> {
        Binding(get: { plan?.entries.first { $0.oid == oid }?.action ?? .pick }, set: { value in
            guard let index = plan?.entries.firstIndex(where: { $0.oid == oid }) else { return }
            plan?.entries[index].action = value; selected = oid
            if value == .squash, index > 0 {
                let previous = plan!.entries[..<index].last { $0.action != .drop }
                plan?.entries[index].message = (previous?.message ?? "") + "\n\n" + plan!.entries[index].subject
            }
        })
    }
    private func messageBinding(_ oid: String) -> Binding<String> {
        Binding(get: { plan?.entries.first { $0.oid == oid }?.message ?? "" }, set: { text in
            if let index = plan?.entries.firstIndex(where: { $0.oid == oid }) { plan?.entries[index].message = text }
        })
    }
    private func move(_ offset: Int) {
        guard let selected, let index = plan?.entries.firstIndex(where: { $0.oid == selected }), let count = plan?.entries.count else { return }
        let next = index + offset; guard next >= 0, next < count else { return }
        plan?.entries.swapAt(index, next)
    }
}

struct OperationBanner: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmAction: String?
    @State private var confirming = false
    @State private var amendMessage = ""
    @State private var amendSheet = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("\(model.operationState.rawValue.capitalized) in progress", systemImage: "exclamationmark.triangle")
                Spacer()
                if model.operationState == .rebase && model.rebaseEditing {
                    Button("Amend Current Commit…") { amendMessage = model.rebaseMessage; amendSheet = true }
                }
                Button("Continue") { control("continue") }.disabled(model.snapshot?.changes.contains(where: \.conflicted) == true)
                if model.operationState == .rebase { Button("Skip…") { confirmAction = "skip"; confirming = true } }
                Button("Abort…") { confirmAction = "abort"; confirming = true }
            }
            if model.operationState == .rebase, let backup = model.lastRebaseBackup { Text("Backup: " + backup).font(.caption).textSelection(.enabled) }
        }.padding(10).background(Color.orange.opacity(0.12)).disabled(model.busy)
            .confirmationDialog(confirmAction == "skip" ? "Skip the current commit?" : "Abort this operation?", isPresented: $confirming) {
                Button(confirmAction == "skip" ? "Skip Commit" : "Abort Operation", role: .destructive) { if let confirmAction { control(confirmAction) } }
            } message: { Text(confirmAction == "skip" ? "The current commit and its conflict-resolution work will not be included." : "Git will restore the pre-operation state. Current conflict-resolution edits may be discarded.") }
            .sheet(isPresented: $amendSheet) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Amend Current Commit").font(.title2.bold())
                    Text("Stage any file changes first. This also supports changing only the message.").font(.caption)
                    TextEditor(text: $amendMessage).frame(height: 120)
                    HStack {
                        Spacer(); Button("Cancel") { amendSheet = false }
                        Button("Amend") {
                            let message = amendMessage; amendSheet = false
                            model.perform("Amend commit") { git, path in try await git.amendRebaseCommit(at: path, message: message) }
                        }.disabled(amendMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }.padding(24).frame(width: 480)
            }
    }
    private func control(_ action: String) {
        let rebase = model.operationState == .rebase
        model.perform(action.capitalized + " " + model.operationState.rawValue) { git, path in
            if rebase { try await git.controlRebase(at: path, action: action) }
            else { try await git.controlMerge(at: path, action: action) }
        }
    }
}
