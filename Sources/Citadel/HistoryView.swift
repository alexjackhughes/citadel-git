import SwiftUI
import GitCore

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel

    private var groups: [(Date, [GitCommit])] {
        var result: [(Date, [GitCommit])] = []
        for commit in model.filteredCommits {
            let day = Calendar.current.startOfDay(for: commit.date)
            if result.last?.0 == day { result[result.count - 1].1.append(commit) }
            else { result.append((day, [commit])) }
        }
        return result
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Label(model.historyBranch ?? model.snapshot?.branch ?? "History", systemImage: "arrow.triangle.branch")
                        .font(.system(size: 11, weight: .medium)).lineLimit(1)
                    Spacer()
                    if model.loading { ProgressView().controlSize(.mini) }
                }.padding(.horizontal, 12).frame(height: 34)
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Filter commits", text: $model.search).textFieldStyle(.plain)
                    if !model.search.isEmpty {
                        Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }.font(.system(size: 11)).padding(9)
                Divider()
                if model.loading {
                    Spacer(); ProgressView("Loading commits…").controlSize(.small); Spacer()
                } else if model.filteredCommits.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "clock").font(.title2).foregroundStyle(.tertiary)
                        Text(model.search.isEmpty ? "No commits yet" : "No matching commits").foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $model.selectedCommit) {
                        ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                            Section {
                                ForEach(group.1) { commit in
                                    CommitRow(commit: commit, selected: model.selectedCommit == commit.hash)
                                        .tag(commit.hash).listRowSeparator(.hidden)
                                        .contextMenu {
                                            Button("Copy Commit Hash") { copy(commit.hash) }
                                            Button("Copy Commit Message") { copy(commit.subject) }
                                        }
                                }
                            } header: { Text(dayLabel(group.0)).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary) }
                        }
                        if model.nextHistoryOffset != nil && model.search.isEmpty {
                            Button(model.loadingMore ? "Loading…" : "Load Older Commits") { Task { await model.loadMoreHistory() } }
                                .disabled(model.loadingMore)
                                .onAppear { Task { await model.loadMoreHistory() } }
                                .frame(maxWidth: .infinity).padding(8)
                        }
                    }.listStyle(.inset)
                }
            }.frame(minWidth: 255, idealWidth: 300, maxWidth: 380, maxHeight: .infinity)
            inspector.frame(minWidth: 350, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: model.search) { _, _ in model.searchHistory() }
        .onChange(of: model.selectedCommit) { _, _ in Task { await model.loadCommit() } }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
    private func dayLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.month(.wide).day().year())
    }

    @ViewBuilder private var inspector: some View {
        if let commit = model.currentCommit, !model.loading {
            VStack(spacing: 0) {
                HStack {
                    Text(commit.shortHash).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    Spacer()
                    Button { copy(commit.hash) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("Copy commit hash")
                    Text("Changeset").font(.system(size: 11, weight: .medium)).padding(.leading, 10)
                }.padding(.horizontal, 16).frame(height: 34)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 14) {
                            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                                metadata("Author", "\(commit.author) <\(commit.email)>")
                                metadata("Date", commit.date.formatted(date: .abbreviated, time: .shortened))
                                metadata("Commit", commit.hash, monospaced: true)
                                if !commit.parents.isEmpty { metadata("Parents", commit.parents.map { String($0.prefix(8)) }.joined(separator: ", "), monospaced: true) }
                                if !commit.refs.isEmpty { metadata("Refs", commit.refs.replacingOccurrences(of: "HEAD -> ", with: "")) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            AuthorAvatar(name: commit.author, size: 36)
                        }
                        Divider()
                        Text(model.detail?.message ?? commit.subject).font(.system(size: 13, weight: .medium))
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        if let detail = model.detail {
                            HStack {
                                Text("Changed Files").font(.system(size: 11, weight: .semibold))
                                Spacer()
                                Text("\(detail.files.count) file\(detail.files.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                            }.padding(.top, 6)
                            VStack(spacing: 1) {
                                ForEach(detail.files, id: \.self) { file in
                                    Button { Task { await model.previewHistoryFile(file) } } label: {
                                        HStack(spacing: 8) {
                                            Image(systemName: model.selectedHistoryFile == file ? "chevron.down" : "chevron.right").font(.system(size: 9)).foregroundStyle(.secondary)
                                            Image(systemName: "doc.text").foregroundStyle(.secondary)
                                            Text(file).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                                            Spacer(minLength: 0)
                                        }.padding(8).contentShape(Rectangle())
                                            .background(model.selectedHistoryFile == file ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 4))
                                    }.buttonStyle(.plain).help(file)
                                }
                            }
                        }
                    }.padding(16)
                }.frame(maxHeight: 280)
                Divider()
                if let document = model.historyDocument {
                    StructuredDiffView(document: document).id(document.id)
                } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
        } else {
            ContentUnavailableView("Commit Details", systemImage: "text.alignleft", description: Text("Select a commit to explore its changes."))
        }
    }

    private func metadata(_ name: String, _ value: String, monospaced: Bool = false) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(name).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).font(.system(size: 11, design: monospaced ? .monospaced : .default)).textSelection(.enabled)
                .lineLimit(2).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.system(size: 11))
    }
}

struct CommitRow: View {
    let commit: GitCommit
    let selected: Bool
    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Rectangle().fill(Color.accentColor.opacity(0.30)).frame(width: 1)
                Circle().fill(selected ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
                    .overlay(Circle().strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 1.5)).frame(width: 7, height: 7)
            }.frame(width: 10)
            AuthorAvatar(name: commit.author, size: 24)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(commit.author).font(.system(size: 10, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 2)
                    Text(commit.date, style: .time).font(.system(size: 9)).foregroundStyle(.secondary)
                }
                Text(commit.subject).font(.system(size: 11)).lineLimit(1)
                HStack(spacing: 5) {
                    Text(commit.shortHash).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                    if !commit.refs.isEmpty {
                        Text(commit.refs.replacingOccurrences(of: "HEAD -> ", with: ""))
                            .font(.system(size: 9, weight: .medium)).foregroundStyle(Color.accentColor).lineLimit(1)
                    }
                }
            }
        }.padding(.vertical, 4)
    }
}

struct AuthorAvatar: View {
    let name: String
    let size: CGFloat
    var body: some View {
        Text(name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased())
            .font(.system(size: size * 0.33, weight: .medium)).frame(width: size, height: size)
            .foregroundStyle(Color.accentColor).background(Color.accentColor.opacity(0.12), in: Circle())
    }
}
