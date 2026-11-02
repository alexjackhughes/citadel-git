import SwiftUI
import GitCore

struct ConflictEditorView: View {
    @EnvironmentObject private var model: AppModel
    let file: String
    @State private var snapshot: ConflictSnapshot?
    @State private var result = ""
    @State private var savedResult = ""
    @State private var showBase = false
    @State private var selectedConflict = 0
    @State private var selectionRequest = UUID()
    @State private var error: String?
    @State private var pending = false
    @State private var reloadConfirmation = false
    @State private var preservedDraft: String?
    @State private var wholeChoice: Int?
    @State private var confirmWholeChoice = false
    private var blocks: [ConflictBlock] { ConflictBlock.parse(result) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(file, systemImage: "exclamationmark.triangle.fill").lineLimit(1)
                Spacer()
                Button("Reload…") { reloadConfirmation = true }
                if preservedDraft != nil { Button("Restore Draft") { result = preservedDraft! } }
            }.padding(10)
            if let snapshot {
                if snapshot.editable {
                    Toggle("Show base", isOn: $showBase).toggleStyle(.checkbox).padding(.horizontal, 10)
                    HSplitView {
                        if showBase { sourcePane("Base", snapshot.version(1)?.text ?? "(File absent)") }
                        sourcePane(snapshot.currentLabel, snapshot.version(2)?.text ?? "(File deleted)")
                        sourcePane(snapshot.incomingLabel, snapshot.version(3)?.text ?? "(File deleted)")
                    }.frame(minHeight: 100, idealHeight: 180, maxHeight: 260)
                    Divider()
                    HStack {
                        Text("Result — \(blocks.count) unresolved conflicts").font(.headline)
                        Spacer()
                        Button("Previous") { selectedConflict = max(0, selectedConflict - 1); selectionRequest = UUID() }.disabled(blocks.isEmpty)
                        Button("Next") { selectedConflict = min(blocks.count - 1, selectedConflict + 1); selectionRequest = UUID() }.disabled(blocks.isEmpty)
                    }.padding(10)
                    if !blocks.isEmpty {
                        let index = min(selectedConflict, blocks.count - 1)
                        HStack {
                            Text("Conflict \(index + 1)").font(.caption)
                            Button("Use Current") { resolve(index, choice: 0) }
                            Button("Use Incoming") { resolve(index, choice: 1) }
                            Button("Use Both") { resolve(index, choice: 2) }
                            Text(String(blocks[index].current.prefix(70)).replacingOccurrences(of: "\n", with: " ↵ ")).lineLimit(1).foregroundStyle(.secondary)
                        }.controlSize(.small).padding(.horizontal, 10)
                    }
                    ConflictResultText(text: $result, target: blocks.isEmpty ? nil : blocks[min(selectedConflict, blocks.count - 1)].range, request: selectionRequest).padding(6)
                } else {
                    ContentUnavailableView("Whole-file Resolution", systemImage: "doc.badge.ellipsis", description: Text("This is a binary, unsupported encoding, link, submodule, or deletion conflict. Choose the version to keep; then mark it resolved. Rename conflicts may involve more than one path."))
                    HStack {
                        Button(snapshot.version(2) == nil ? "Use Current Deletion…" : "Use Current File…") { wholeChoice = snapshot.version(2) == nil ? nil : 2; confirmWholeChoice = true }
                        Button(snapshot.version(3) == nil ? "Use Incoming Deletion…" : "Use Incoming File…") { wholeChoice = snapshot.version(3) == nil ? nil : 3; confirmWholeChoice = true }
                    }.padding(10)
                    Button("Open in External Editor") {
                        if let path = model.selectedRepository { NSWorkspace.shared.open(URL(fileURLWithPath: path).appendingPathComponent(file)) }
                    }
                }
                Divider()
                HStack {
                    if result != savedResult { Text("Unsaved result").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Save Result") { save(snapshot) }.disabled(!snapshot.editable || result == savedResult)
                    Button("Mark Resolved") {
                        model.perform("Mark resolved") { git, path in try await git.markResolved(at: path, snapshot: snapshot) }
                    }.buttonStyle(.borderedProminent).disabled(result != savedResult || ConflictBlock.hasMarkers(result))
                }.padding(10)
            } else if error == nil { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled).padding(10) }
        }.disabled(pending || model.busy).task(id: file) { await load() }
            .confirmationDialog("Reload the conflict from disk?", isPresented: $reloadConfirmation) {
                Button("Preserve Draft and Reload") { preservedDraft = result; Task { await load() } }
            } message: { Text("Your draft will be retained in this editor so you can restore or copy it after reloading.") }
            .confirmationDialog("Replace the working file with this version?", isPresented: $confirmWholeChoice) {
                Button("Replace Working File", role: .destructive) { chooseWhole() }
            } message: { Text("This saves the selected version or deletion. It does not stage the resolution.") }
    }
    private func sourcePane(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption.bold()).padding(6)
            ScrollView([.horizontal, .vertical]) { Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(6) }
        }.frame(minWidth: 120)
    }
    private func load() async {
        guard let path = model.selectedRepository else { return }
        pending = true; error = nil
        defer { pending = false }
        do {
            let loaded = try await model.git.conflict(at: path, file: file)
            guard !Task.isCancelled else { return }
            snapshot = loaded; result = loaded.result ?? ""; savedResult = result; selectedConflict = 0
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    private func resolve(_ index: Int, choice: Int) {
        let block = blocks[index]
        result = (result as NSString).replacingCharacters(in: block.range, with: choice == 0 ? block.current : choice == 1 ? block.incoming : block.current + block.incoming)
        selectedConflict = min(index, max(0, blocks.count - 1))
    }
    private func save(_ snapshot: ConflictSnapshot) {
        guard let path = model.selectedRepository else { return }
        let draft = result; pending = true
        Task {
            defer { pending = false }
            do { let updated = try await model.git.saveConflict(at: path, snapshot: snapshot, result: draft); self.snapshot = updated; result = updated.result ?? draft; savedResult = result; error = nil }
            catch { self.error = error.localizedDescription }
        }
    }
    private func chooseWhole() {
        guard let path = model.selectedRepository, let snapshot else { return }
        pending = true
        Task {
            defer { pending = false }
            do { let updated = try await model.git.chooseConflictVersion(at: path, snapshot: snapshot, stage: wholeChoice); self.snapshot = updated; result = updated.result ?? ""; savedResult = result; error = nil }
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct ConflictResultText: NSViewRepresentable {
    @Binding var text: String
    let target: NSRange?
    let request: UUID
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true
        let view = NSTextView(); view.isRichText = false; view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false; view.isAutomaticTextReplacementEnabled = false
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.isVerticallyResizable = true; view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.delegate = context.coordinator; view.setAccessibilityLabel("Conflict result")
        scroll.documentView = view; return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }
        if view.string != text { view.string = text }
        if context.coordinator.request != request {
            context.coordinator.request = request
            if let target, NSMaxRange(target) <= view.string.utf16.count {
                view.setSelectedRange(target); view.scrollRangeToVisible(target)
            }
        }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? { CGSize(width: proposal.width ?? 400, height: proposal.height ?? 240) }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ConflictResultText; var request: UUID?
        init(_ parent: ConflictResultText) { self.parent = parent }
        func textDidChange(_ notification: Notification) { if let view = notification.object as? NSTextView { parent.text = view.string } }
    }
}
