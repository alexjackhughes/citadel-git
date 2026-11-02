import SwiftUI
import AppKit

@main
struct CitadelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Citadel", id: "workspace") {
            ContentView().environmentObject(model)
                .frame(minWidth: 940, minHeight: 600)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    if !model.busy { Task { await model.refresh() } }
                }
                .alert("Git couldn’t complete that", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                    Button("OK", role: .cancel) { model.error = nil }
                } message: { Text(model.error ?? "") }
        }
        .defaultSize(width: 1180, height: 760)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Repository…") { model.addRepository() }.keyboardShortcut("o")
                Button("Clone Repository…") { model.creationMode = .clone }.disabled(model.busy)
                Button("New Repository…") { model.creationMode = .initialize }.disabled(model.busy)
            }
            CommandMenu("Repository") {
                Button("Refresh") { Task { await model.refresh() } }.keyboardShortcut("r").disabled(model.selectedRepository == nil || model.busy)
                Button("Show in Finder") { model.revealRepository() }.keyboardShortcut("r", modifiers: [.command, .shift]).disabled(model.selectedRepository == nil)
                Divider()
                Button("Show History") { model.navigate("history") }.keyboardShortcut("1")
                Button("Show Working Copy") { model.navigate("working") }.keyboardShortcut("2")
                Button("Show Stashes") { model.navigate("stashes") }.keyboardShortcut("3")
                Button("Create Stash…") { model.showCreateStash = true }.disabled(model.snapshot == nil || model.busy)
                Divider()
                Button("Stage All") { model.stageAll() }.keyboardShortcut("a", modifiers: [.command, .shift]).disabled(model.unstagedFiles.isEmpty || model.busy)
                Button("Commit Staged Changes") { model.commit() }.keyboardShortcut(.return, modifiers: [.command]).disabled(!model.canCommit)
                Divider()
                Button("Interactive Rebase…") { model.rebaseUpstream = nil; model.showRebase = true }.disabled(model.snapshot == nil || model.busy || model.operationState != .idle)
                Button("New Branch…") { model.showNewBranch = true }.keyboardShortcut("b", modifiers: [.command, .shift]).disabled(model.snapshot == nil)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let url = Bundle.main.url(forResource: "CitadelLighthouse", withExtension: "icns"),
           let image = NSImage(contentsOf: url) { NSApp.applicationIconImage = image }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
