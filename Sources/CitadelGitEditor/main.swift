import Foundation

struct Entry: Decodable { let oid: String; let action: String; let message: String }
struct Session: Decodable { let entries: [Entry]; let gitDirectory: String }
do {
    guard let file = ProcessInfo.processInfo.environment["CITADEL_REBASE_SESSION"], CommandLine.arguments.count == 3 else { throw NSError(domain: "Missing rebase session", code: 1) }
    let session = try JSONDecoder().decode(Session.self, from: Data(contentsOf: URL(fileURLWithPath: file)))
    let target = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
    let gitDirectory = URL(fileURLWithPath: session.gitDirectory).standardizedFileURL
    guard target.path.hasPrefix(gitDirectory.path + "/") else { throw NSError(domain: "Editor target outside Git directory", code: 2) }
    let allowed = Set(["pick", "reword", "squash", "fixup", "drop", "edit"])
    guard session.entries.allSatisfy({ allowed.contains($0.action) && [40,64].contains($0.oid.count) && $0.oid.allSatisfy { "0123456789abcdef".contains($0) } }) else { throw NSError(domain: "Invalid rebase plan", code: 3) }
    if CommandLine.arguments[1] == "sequence" {
        let todo = session.entries.map { "\($0.action) \($0.oid)" }.joined(separator: "\n") + "\n"
        try todo.write(to: target, atomically: true, encoding: .utf8)
    } else if CommandLine.arguments[1] == "message" {
        let done = try String(contentsOf: gitDirectory.appendingPathComponent("rebase-merge/done"), encoding: .utf8)
        let commands = done.split(separator: "\n").filter { !$0.hasPrefix("#") && !$0.isEmpty }.map { $0.split(separator: " ") }
        var chosen: Entry?
        for command in commands.reversed() {
            guard command.count >= 2 else { continue }
            let action = String(command[0])
            if action == "drop" || action == "fixup" { continue }
            if ["reword", "squash"].contains(action) {
                chosen = session.entries.first { $0.oid.hasPrefix(String(command[1])) }
            }
            break
        }
        // Git defers a squash editor until the end of a following fixup chain.
        if let entry = chosen {
            guard !entry.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NSError(domain: "Empty commit message", code: 4) }
            try (entry.message + "\n").write(to: target, atomically: true, encoding: .utf8)
        }
    } else { throw NSError(domain: "Unknown editor mode", code: 5) }
} catch {
    FileHandle.standardError.write(Data("Citadel rebase editor: \(error.localizedDescription)\n".utf8)); exit(1)
}
