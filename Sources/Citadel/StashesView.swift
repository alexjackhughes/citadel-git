import SwiftUI
import GitCore

struct StashesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selected: String?
    @State private var files: [String] = []
    @State private var selectedFile: String?
    @State private var document: DiffDocument?
    @State private var restoreIndex = false
    @State private var deleting = false
    var body: some View {
        HSplitView {
            VStack {
                HStack { Text("Stashes").font(.headline); Spacer(); Button("New Stash…") { model.showCreateStash = true } }.padding(12)
                List(model.stashes, selection: $selected) { stash in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(stash.message).lineLimit(2)
                        Text(stash.date, style: .date).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 5).tag(stash.oid)
                }
            }.frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
            VStack(spacing: 0) {
                if let selected {
                    HStack {
                        Toggle("Restore staged state", isOn: $restoreIndex).toggleStyle(.checkbox)
                        Spacer()
                        Button("Apply") { apply(selected, pop: false) }
                        Button("Pop") { apply(selected, pop: true) }
                        Button("Delete…", role: .destructive) { deleting = true }
                    }.padding(12).disabled(model.busy)
                    Divider()
                    List(files, id: \.self, selection: $selectedFile) { Text($0).font(.system(.body, design: .monospaced)).tag($0) }.frame(height: 150)
                    Divider()
                    if let document { StructuredDiffView(document: document).id(document.id) }
                    else { ContentUnavailableView("Stash Preview", systemImage: "archivebox", description: Text("Select a file to review.")) }
                } else { ContentUnavailableView("Stashes", systemImage: "archivebox", description: Text("Save unfinished work and restore it later.")) }
            }.frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: selected) {
            files = []; selectedFile = nil; document = nil
            guard let selected, let path = model.selectedRepository else { return }
            do {
                let result = try await model.git.stashFiles(at: path, oid: selected)
                guard !Task.isCancelled else { return }; files = result; selectedFile = result.first
            } catch is CancellationError {} catch { model.error = error.localizedDescription }
        }
        .task(id: selectedFile) {
            document = nil
            guard let selected, let file = selectedFile, let path = model.selectedRepository else { return }
            do { let result = try await model.git.stashDiff(at: path, oid: selected, file: file); if !Task.isCancelled { document = result } }
            catch is CancellationError {} catch { model.error = error.localizedDescription }
        }
        .onChange(of: model.stashes.map(\.oid)) { _, ids in if let selected, !ids.contains(selected) { self.selected = nil } }
        .confirmationDialog("Delete this stash permanently?", isPresented: $deleting) {
            Button("Delete Stash", role: .destructive) {
                if let selected { model.perform("Delete stash") { git, path in try await git.deleteStash(at: path, oid: selected) } }
            }
        } message: { Text("This removes the stash reference. Apply it first if you need to keep its changes.") }
    }
    private func apply(_ oid: String, pop: Bool) {
        let restore = restoreIndex
        model.perform(pop ? "Pop stash" : "Apply stash") { git, path in
            try await git.applyStash(at: path, oid: oid, pop: pop, restoreIndex: restore)
        }
    }
}
struct CreateStashView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var includeUntracked = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Save Work in a Stash").font(.title2.bold())
            TextField("Stash message (optional)", text: $message).textFieldStyle(.roundedBorder)
            Toggle("Include untracked files", isOn: $includeUntracked)
            Text("Ignored files are not included.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer(); Button("Cancel") { dismiss() }
                Button("Create Stash") {
                    let text = message, untracked = includeUntracked
                    dismiss()
                    model.perform("Create stash") { git, path in try await git.createStash(at: path, message: text, includeUntracked: untracked) }
                }.disabled(model.busy || model.snapshot?.changes.isEmpty != false)
            }
        }.padding(24).frame(width: 420)
    }
}
