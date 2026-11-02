import SwiftUI
import GitCore

struct StructuredDiffView: View {
    @EnvironmentObject private var model: AppModel
    let document: DiffDocument
    var allowsStaging = false
    @State private var lines: [DiffLine] = []
    @State private var hunks: [DiffHunk] = []
    @State private var selection: Set<Int> = []
    @State private var complete = false
    @State private var loading = false
    @State private var failure: String?

    private var selectedHunk: DiffHunk? {
        guard let line = lines.first(where: { selection.contains($0.id) }), let hunk = line.hunk else { return nil }
        return hunks.first { $0.id == hunk }
    }
    private var changedSelection: Set<Int> { Set(lines.filter { selection.contains($0.id) && ($0.kind == .addition || $0.kind == .deletion) }.map(\.id)) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(hunks.count) \(hunks.count == 1 ? "hunk" : "hunks")\(complete ? "" : " loaded")").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if allowsStaging && document.partialStagingAllowed {
                    Button(document.staged ? "Unstage Hunk" : "Stage Hunk") {
                        if let hunk = selectedHunk { apply(Set(hunk.lineIDs)) }
                    }.disabled(model.busy || selectedHunk?.complete != true)
                    Button(document.staged ? "Unstage Selected Lines" : "Stage Selected Lines") { apply(changedSelection) }
                        .disabled(model.busy || changedSelection.isEmpty || hunks.contains { !changedSelection.isDisjoint(with: $0.lineIDs) && !$0.complete })
                } else if allowsStaging { Text("Whole-file staging only").font(.caption).foregroundStyle(.secondary) }
            }.controlSize(.small).padding(8)
            Divider()
            DiffTable(lines: lines, selection: $selection, loadMore: { Task { await more() } })
            if let failure { Text(failure).foregroundStyle(.red).padding(8) }
            if !complete {
                Button(loading ? "Loading…" : "Load More Diff") { Task { await more() } }.disabled(loading).padding(6)
            } else if lines.isEmpty { Text("No text changes in this view.").foregroundStyle(.secondary).padding(8) }
        }.task { await more() }
    }
    private func more() async {
        guard !loading, !complete else { return }
        loading = true
        defer { loading = false }
        do {
            let page = try await document.nextPage()
            guard !Task.isCancelled else { return }
            lines += page.lines; hunks = page.hunks; complete = page.complete
        } catch is CancellationError {} catch { failure = error.localizedDescription }
    }
    private func apply(_ ids: Set<Int>) {
        model.perform(document.staged ? "Unstage selection" : "Stage selection") { git, path in
            try await git.applySelection(at: path, document: document, selected: ids)
        }
    }
}

private struct DiffTable: NSViewRepresentable {
    let lines: [DiffLine]
    @Binding var selection: Set<Int>
    let loadMore: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        let table = CopyableDiffTable()
        table.headerView = nil; table.rowHeight = 21; table.intercellSpacing = NSSize(width: 6, height: 0)
        table.allowsMultipleSelection = true; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.setAccessibilityLabel("Diff lines")
        for (id, width) in [("old", CGFloat(52)), ("new", 52), ("text", 900)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.width = width
            if id != "text" { column.minWidth = width; column.maxWidth = width }
            table.addTableColumn(column)
        }
        table.delegate = context.coordinator; table.dataSource = context.coordinator
        table.copyRows = { [weak coordinator = context.coordinator] indexes in
            guard let coordinator else { return "" }
            return indexes.compactMap { coordinator.parent.lines.indices.contains($0) ? coordinator.parent.lines[$0].text : nil }.joined(separator: "\n")
        }
        scroll.documentView = table
        return scroll
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 600, height: proposal.height ?? 400)
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let table = scroll.documentView as? NSTableView else { return }
        if context.coordinator.count != lines.count {
            context.coordinator.count = lines.count
            table.reloadData()
        }
    }
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: DiffTable; var count = -1
        init(_ parent: DiffTable) { self.parent = parent }
        func numberOfRows(in tableView: NSTableView) -> Int { parent.lines.count }
        func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
            guard parent.lines.indices.contains(row), let column else { return nil }
            let line = parent.lines[row]
            let field = (tableView.makeView(withIdentifier: column.identifier, owner: self) as? NSTextField) ?? NSTextField(labelWithString: "")
            field.identifier = column.identifier
            field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            field.lineBreakMode = .byClipping
            field.textColor = column.identifier.rawValue == "text" ? .labelColor : .secondaryLabelColor
            switch column.identifier.rawValue {
            case "old": field.stringValue = line.oldNumber.map(String.init) ?? ""; field.alignment = .right
            case "new": field.stringValue = line.newNumber.map(String.init) ?? ""; field.alignment = .right
            default: field.stringValue = line.text
            }
            if row >= parent.lines.count - 20 { DispatchQueue.main.async { self.parent.loadMore() } }
            return field
        }
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view = DiffRowView()
            switch parent.lines[row].kind {
            case .addition: view.tint = .systemGreen.withAlphaComponent(0.14)
            case .deletion: view.tint = .systemRed.withAlphaComponent(0.14)
            case .header: view.tint = .systemBlue.withAlphaComponent(0.08)
            default: view.tint = .textBackgroundColor
            }
            return view
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table = notification.object as? NSTableView else { return }
            parent.selection = Set(table.selectedRowIndexes.compactMap { parent.lines.indices.contains($0) ? parent.lines[$0].id : nil })
        }
    }
}
private final class CopyableDiffTable: NSTableView {
    var copyRows: ((IndexSet) -> String)?
    @objc func copy(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyRows?(selectedRowIndexes) ?? "", forType: .string)
    }
}

private final class DiffRowView: NSTableRowView {
    var tint = NSColor.textBackgroundColor
    override func drawBackground(in dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill(); dirtyRect.fill()
        tint.setFill(); dirtyRect.fill()
    }
}
