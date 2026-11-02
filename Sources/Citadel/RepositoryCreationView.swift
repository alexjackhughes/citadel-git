import SwiftUI

enum CreationMode: String, Identifiable { case clone, initialize; var id: String { rawValue } }
struct RepositoryCreationView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let mode: CreationMode
    @State private var source = ""
    @State private var folder = ""
    @State private var name = ""
    @State private var branch = "main"
    @State private var attempted = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(mode == .clone ? "Clone Repository" : "New Repository").font(.title2.bold())
            if mode == .clone {
                TextField("HTTPS / SSH URL or local source", text: $source).textFieldStyle(.roundedBorder)
                Text("Uses your Git credential helper or SSH agent. Do not paste tokens or passwords.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text(folder.isEmpty ? (mode == .clone ? "Choose a parent folder" : "Choose a folder to initialize") : folder).lineLimit(2).truncationMode(.middle)
                Spacer()
                Button("Choose…") {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
                    if panel.runModal() == .OK { folder = panel.url?.path ?? "" }
                }
            }
            if mode == .clone { TextField("New destination folder name", text: $name).textFieldStyle(.roundedBorder) }
            else {
                TextField("Initial branch", text: $branch).textFieldStyle(.roundedBorder)
                Text("Existing files are preserved. An existing repository will be opened; nothing is staged or committed.").font(.caption).foregroundStyle(.secondary)
            }
            if attempted && !model.busy {
                Text("If cloning was interrupted, its partial folder is preserved. Choose a different name to retry.").font(.caption).foregroundStyle(.secondary)
                Button("Reveal Destination") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: mode == .clone ? URL(fileURLWithPath: folder).appendingPathComponent(name).path : folder) }
            }
            if model.busy {
                ProgressView(model.status).controlSize(.small)
                Text(model.operationProgress).font(.caption).lineLimit(3)
                Button("Cancel Operation") { model.cancelOperation() }
            }
            HStack {
                Spacer(); Button("Close") { dismiss() }.disabled(model.busy)
                Button(attempted ? "Retry" : mode == .clone ? "Clone" : "Initialize / Open") {
                    attempted = true
                    model.createRepository(mode: mode, source: source, folder: folder, name: name, branch: branch)
                }.buttonStyle(.borderedProminent)
                    .disabled(model.busy || folder.isEmpty || (mode == .clone ? source.isEmpty || name.isEmpty : branch.isEmpty))
            }
        }.padding(24).frame(width: 500)
    }
}
