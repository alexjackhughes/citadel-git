import SwiftUI
import GitCore
import UniformTypeIdentifiers

@MainActor
private enum FileIcons {
    private static var cache: [String: NSImage] = [:]
    static func icon(for path: String) -> NSImage {
        let ext = (path as NSString).pathExtension.lowercased()
        if let icon = cache[ext] { return icon }
        let icon = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        cache[ext] = icon
        return icon
    }
}


struct ChangesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedPaths: Set<String> = []
    @FocusState private var focus: Focus?
    private enum Focus: Hashable { case files, subject }

    private var selected: ChangedFile? { model.snapshot?.changes.first { $0.path == model.selectedFile } }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 5) {
                    Text(model.snapshot?.branch ?? "Working Copy")
                    if let upstream = model.snapshot?.upstream, !upstream.isEmpty {
                        Image(systemName: "chevron.right").font(.system(size: 9))
                        Text(upstream).foregroundStyle(.tertiary)
                    }
                    Spacer()
                }.font(.system(size: 12)).foregroundStyle(.secondary).padding(14)
                Divider()
                commitComposer
                Divider()
                HStack(spacing: 12) {
                    Text("Status").frame(width: 66, alignment: .leading)
                    Text("Filename")
                    Spacer()
                }.font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.vertical, 8).background(.bar)
                Divider()
                if model.snapshot?.changes.isEmpty == true {
                    ContentUnavailableView("Working Tree Clean", systemImage: "checkmark.circle", description: Text("All your changes are committed."))
                        .frame(maxHeight: .infinity)
                } else {
                    List(selection: $selectedPaths) {
                        ForEach(model.snapshot?.changes ?? []) { file in
                            fileRow(file).tag(file.path)
                                .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                        }
                    }
                    .listStyle(.plain)
                    .focused($focus, equals: .files)
                    .onKeyPress(.tab) {
                        focus = .subject
                        return .handled
                    }
                    .onKeyPress(.space) {
                        model.toggleStaging(selectedPaths)
                        return .handled
                    }
                    .onKeyPress(characters: CharacterSet(charactersIn: "a")) { press in
                        guard press.modifiers == .command else { return .ignored }
                        selectedPaths = Set(model.snapshot?.changes.map(\.path) ?? [])
                        return .handled
                    }
                    .accessibilityLabel("Changed files")
                }
                Divider()
                HStack {
                    Text(selectedPaths.count > 1 ? "\(selectedPaths.count) selected · Space to stage" : "\(model.snapshot?.changes.count ?? 0) changed files")
                    Spacer()
                    Text("\(model.stagedFiles.count) staged")
                }.font(.system(size: 10)).foregroundStyle(.secondary).padding(10)
            }.frame(minWidth: 280, idealWidth: 350, maxWidth: 480)
            VStack(spacing: 0) {
                if let file = selected {
                    HStack(spacing: 8) {
                        Image(nsImage: FileIcons.icon(for: file.path)).resizable().frame(width: 20, height: 20)
                        Text(URL(fileURLWithPath: file.path).lastPathComponent).font(.system(size: 13, weight: .semibold)).lineLimit(1).help(file.path)
                        Spacer()
                        Picker("Changes", selection: Binding(get: { model.selectedFileStaged }, set: { staged in
                            Task { await model.previewFile(file.path, staged: staged) }
                        })) {
                            Text("Staged").tag(true)
                            Text("Unstaged").tag(false)
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 170).disabled(model.busy || model.loading)
                    }.padding(.horizontal, 14).frame(height: 44)
                    Divider()
                    HStack {
                        Text(DiffSummary(text: model.diff).label).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        Spacer()
                        Button(model.selectedFileStaged ? "Unstage File" : "Stage File") {
                            if model.selectedFileStaged { model.unstage(file) } else { model.stage(file) }
                        }.controlSize(.small)
                            .disabled(model.busy || model.loading || (model.selectedFileStaged ? !file.staged : !file.unstaged))
                    }.padding(.horizontal, 14).padding(.vertical, 8).background(.bar)
                    Divider()
                    DiffBody(text: model.diff)
                } else {
                    ContentUnavailableView("Change Preview", systemImage: "doc.text.magnifyingglass", description: Text("Select a file to review its changes."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.background(Color(nsColor: .textBackgroundColor))
                .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { focus = .files }
        .onChange(of: selectedPaths) { old, new in
            let added = new.subtracting(old)
            let files = model.snapshot?.changes ?? []
            if let file = files.first(where: { added.contains($0.path) }) ?? files.first(where: { new.contains($0.path) }) {
                Task { await model.previewFile(file.path, staged: !file.unstaged && file.staged) }
            }
        }
        .onChange(of: model.selectedRepository) { _, _ in selectedPaths = []; focus = .files }
        .onChange(of: model.snapshot?.changes.map(\.path)) { _, paths in
            selectedPaths.formIntersection(Set(paths ?? []))
        }
    }

    private func fileRow(_ file: ChangedFile) -> some View {
        let isSelected = selectedPaths.contains(file.path)
        return HStack(spacing: 10) {
            Button {
                if file.staged && !file.unstaged { model.unstage(file) } else { model.stage(file) }
            } label: {
                Image(systemName: file.staged ? (file.unstaged ? "minus.square.fill" : "checkmark.square.fill") : "square")
                    .font(.system(size: 16)).foregroundStyle(isSelected ? Color.white : file.staged ? Color.accentColor : Color.secondary)
            }.buttonStyle(.plain).disabled(model.busy || model.loading)
                .accessibilityLabel(file.staged && !file.unstaged ? "Unstage \(file.path)" : "Stage \(file.path)")
                .help(file.staged && file.unstaged ? "Partially staged. Click to stage remaining changes." : file.staged ? "Unstage file" : "Stage file")
            HStack(spacing: 9) {
                    Text(file.conflicted ? "!" : file.index == "?" ? "?" : String(file.unstaged ? file.worktree : file.index))
                        .font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(.white)
                        .frame(width: 17, height: 18).background(file.conflicted ? Color.orange : file.index == "?" ? Color.gray : Color.blue, in: RoundedRectangle(cornerRadius: 3))
                    Image(nsImage: FileIcons.icon(for: file.path)).resizable().frame(width: 16, height: 16)
                    Text(file.path).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
            }.contentShape(Rectangle()).help(file.path)
        }.padding(.horizontal, 8).frame(height: 31)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .contextMenu {
                Button("Stage File") { model.stage(file) }.disabled(!file.unstaged || model.busy || model.loading)
                Button("Unstage File") { model.unstage(file) }.disabled(!file.staged || model.busy || model.loading)
            }
    }

    private var commitComposer: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Commit Subject", text: $model.message)
                .focused($focus, equals: .subject)
                .onSubmit { model.commit() }
                .onKeyPress(.tab) {
                    focus = .files
                    return .handled
                }
                .lineLimit(1).textFieldStyle(.roundedBorder).font(.system(size: 13))
                .accessibilityLabel("Commit message").disabled(model.busy)
            HStack {
                Button("Stage All") { model.stageAll() }.disabled(model.unstagedFiles.isEmpty || model.busy || model.loading)
                if !model.stagedFiles.isEmpty {
                    Button("Unstage All") { model.unstageAll() }.disabled(model.busy || model.loading)
                }
                Spacer()
                Button("Commit") { model.commit() }.disabled(!model.canCommit)
                    .help("Return from the commit subject, or ⌘ Return anywhere")
            }.controlSize(.small)
        }.padding(16)
    }
}

struct DiffSummary {
    let chunks: Int
    let additions: Int
    let deletions: Int
    init(text: String) {
        let lines = text.components(separatedBy: "\n")
        additions = lines.filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.count
        deletions = lines.filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }.count
        chunks = max(lines.filter { $0.hasPrefix("@@ ") }.count, additions > 0 || deletions > 0 ? 1 : 0)
    }
    var label: String { "\(chunks) \(chunks == 1 ? "chunk" : "chunks"), \(additions) insertions, \(deletions) deletions" }
}

struct DiffBody: View {
    let text: String
    var body: some View {
        // Keep the native editor alive between selections instead of tearing down
        // its text storage, layout manager and scroll view on every click.
        NativeDiffText(text: text)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if text.isEmpty {
                    ContentUnavailableView("No Text Changes", systemImage: "doc", description: Text("There are no text changes in this view. Binary files and permission changes may have no text diff."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(nsColor: .textBackgroundColor))
                }
            }
    }
}

struct DiffView: View {
    let text: String
    let filename: String?
    let subtitle: String
    var body: some View {
        VStack(spacing: 0) {
            if let filename {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text").foregroundStyle(.secondary)
                    Text(filename).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle).help(filename)
                    Spacer(minLength: 10)
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
                }.padding(.horizontal, 12).padding(.vertical, 9)
                Divider()
                DiffBody(text: text)
            } else {
                ContentUnavailableView("Change Preview", systemImage: "doc.text.magnifyingglass", description: Text("Select a file to review its changes."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.background(Color(nsColor: .textBackgroundColor))
    }
}

private let diffRowColor = NSAttributedString.Key("CitadelDiffRowColor")

private final class DiffLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        enumerateLineFragments(forGlyphRange: glyphsToShow) { rect, _, container, range, _ in
            let character = self.characterIndexForGlyph(at: range.location)
            if let color = self.textStorage?.attribute(diffRowColor, at: character, effectiveRange: nil) as? NSColor {
                color.setFill()
                let width = max(container.textView?.bounds.width ?? rect.width, rect.width)
                NSRect(x: 0, y: rect.minY + origin.y, width: width, height: rect.height).fill()
            }
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }
}

// Native text selection and efficient rendering even for large diffs.
struct NativeDiffText: NSViewRepresentable {
    let text: String
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        let storage = NSTextStorage()
        let layout = DiffLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: 100_000, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout); layout.addTextContainer(container)
        let view = NSTextView(frame: .zero, textContainer: container)
        view.isEditable = false; view.isSelectable = true; view.isRichText = true
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainerInset = NSSize(width: 10, height: 8)
        container.widthTracksTextView = true
        view.maxSize = NSSize(width: 100_000, height: CGFloat.greatestFiniteMagnitude)
        view.backgroundColor = .textBackgroundColor
        view.setAccessibilityLabel("File diff")
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        let key = text + "\(colorScheme)"
        guard context.coordinator.last != key else { return }
        context.coordinator.last = key
        let output = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 3
        var old = 0, new = 0, inHunk = false
        let hasHunks = text.contains("@@ ")
        output.beginEditing()
        for line in text.components(separatedBy: "\n") {
            var foreground = NSColor.labelColor
            var background = NSColor.clear
            var prefix = "              "
            var content = line
            if line.hasPrefix("@@ ") {
                let fields = line.split(separator: " ")
                if fields.count >= 3 {
                    old = Int(fields[1].dropFirst().split(separator: ",")[0]) ?? 0
                    new = Int(fields[2].dropFirst().split(separator: ",")[0]) ?? 0
                }
                inHunk = true
                foreground = .secondaryLabelColor; background = NSColor.quaternaryLabelColor.withAlphaComponent(0.08)
            } else if inHunk || (!hasHunks && line.hasPrefix("+")) {
                if line.hasPrefix("+") {
                    if !hasHunks { new += 1 }
                    prefix = String(format: "       %5d + ", new)
                    if hasHunks { new += 1 }
                    background = NSColor.systemGreen.withAlphaComponent(0.13)
                    content = String(line.dropFirst())
                } else if line.hasPrefix("-") {
                    prefix = String(format: "%6d       − ", old); old += 1
                    background = NSColor.systemRed.withAlphaComponent(0.13)
                    content = String(line.dropFirst())
                } else if line.hasPrefix(" ") {
                    prefix = String(format: "%6d %5d   ", old, new); old += 1; new += 1
                    content = String(line.dropFirst())
                } else { foreground = .secondaryLabelColor }
            } else {
                // File headers are already represented by the inspector header.
                if hasHunks { continue }
                foreground = .secondaryLabelColor
            }
            let row = NSMutableAttributedString(string: prefix + content + "\n", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: foreground, diffRowColor: background, .paragraphStyle: paragraph])
            row.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: NSRange(location: 0, length: prefix.utf16.count))
            output.append(row)
        }
        output.endEditing()
        view.textStorage?.setAttributedString(output)
        view.scrollToBeginningOfDocument(nil)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 400, height: proposal.height ?? 240)
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var last = "" }
}
