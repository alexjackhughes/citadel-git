import Foundation

public struct ConflictVersion: Sendable {
    public let stage: Int
    public let mode: String
    public let oid: String
    public let data: Data
    public var text: String? { !data.contains(0) ? String(data: data, encoding: .utf8) : nil }
}
public struct ConflictSnapshot: Sendable {
    public let file: String
    public let versions: [ConflictVersion]
    public let fingerprint: SourceFingerprint
    public let result: String?
    public let currentLabel: String
    public let incomingLabel: String
    public let crlf: Bool
    public var editable: Bool { result != nil && versions.allSatisfy { ["100644", "100755"].contains($0.mode) && $0.text != nil } }
    public func version(_ stage: Int) -> ConflictVersion? { versions.first { $0.stage == stage } }
}
public struct ConflictBlock: Identifiable, Sendable {
    public var id: Int { range.location }
    public let range: NSRange
    public let current: String
    public let incoming: String
    public static func parse(_ text: String) -> [ConflictBlock] {
        let lines = text.components(separatedBy: "\n")
        var offset = 0, start: Int?, middle = false, inBase = false, current = "", incoming = ""
        var results: [ConflictBlock] = []
        for (index, line) in lines.enumerated() {
            let full = line + (index < lines.count - 1 ? "\n" : "")
            if line.hasPrefix("<<<<<<<") { start = offset; middle = false; inBase = false; current = ""; incoming = "" }
            else if start != nil && line.hasPrefix("|||||||") { inBase = true }
            else if start != nil && line.hasPrefix("=======") { middle = true; inBase = false }
            else if let beginning = start, line.hasPrefix(">>>>>>>") {
                results.append(ConflictBlock(range: NSRange(location: beginning, length: offset + full.utf16.count - beginning), current: current, incoming: incoming)); start = nil
            } else if start != nil {
                if middle { incoming += full } else if !inBase { current += full }
            }
            offset += full.utf16.count
        }
        return results
    }
    public static func hasMarkers(_ text: String) -> Bool {
        text.range(of: #"(?m)^(<<<<<<<|=======|>>>>>>>|\|\|\|\|\|\|\|)"#, options: .regularExpression) != nil
    }
}

extension GitRepository {
    func worktreeURL(at path: String, file: String) throws -> URL {
        guard !file.isEmpty, !file.hasPrefix("/"), !file.components(separatedBy: "/").contains("..") else { throw GitFailure("Invalid repository path.") }
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let target = root.appendingPathComponent(file)
        let parent = target.deletingLastPathComponent().resolvingSymlinksInPath().path
        guard parent == root.path || parent.hasPrefix(root.path + "/") else { throw GitFailure("A parent directory points outside the repository.") }
        return target
    }
    public func conflict(at path: String, file: String) async throws -> ConflictSnapshot {
        let target = try worktreeURL(at: path, file: file)
        let before = try await fingerprint(at: path, file: file)
        let entries = try await run(path, ["ls-files", "--unmerged", "-z", "--", file])
        var versions: [ConflictVersion] = []
        for record in entries.split(separator: "\0") {
            guard let header = record.split(separator: "\t", maxSplits: 1).first else { continue }
            let fields = header.split(separator: " "); guard fields.count == 3, let stage = Int(fields[2]) else { continue }
            let output = try await GitProcess.execute(at: path, arguments: ["cat-file", "blob", String(fields[1])])
            versions.append(ConflictVersion(stage: stage, mode: String(fields[0]), oid: String(fields[1]), data: try Data(contentsOf: output.stdout)))
        }
        guard !versions.isEmpty else { throw GitFailure("This file no longer has unmerged index entries. Refresh the repository.") }
        let state = try await operationState(at: path)
        let current = try await run(path, ["rev-parse", "--short", "HEAD"], allowFailure: true).trimmingCharacters(in: .newlines)
        let incoming = try await run(path, ["rev-parse", "--short", state == .rebase ? "REBASE_HEAD" : "MERGE_HEAD"], allowFailure: true).trimmingCharacters(in: .newlines)
        let type = (try? FileManager.default.attributesOfItem(atPath: target.path)[.type]) as? FileAttributeType
        let data = type == .typeRegular ? (try? Data(contentsOf: target)) : nil
        let result = data.flatMap { $0.contains(0) ? nil : String(data: $0, encoding: .utf8) }
        guard before == (try await fingerprint(at: path, file: file)) else { throw GitFailure("Conflict changed while loading. Reload it.") }
        return ConflictSnapshot(file: file, versions: versions, fingerprint: before, result: result,
                                currentLabel: state == .rebase ? "Current: rebased history \(current)" : "Current: HEAD \(current)",
                                incomingLabel: state == .rebase ? "Incoming: replayed commit \(incoming)" : "Incoming: \(incoming.isEmpty ? "stash / other side" : incoming)", crlf: result?.contains("\r\n") == true)
    }
    public func saveConflict(at path: String, snapshot: ConflictSnapshot, result: String) async throws -> ConflictSnapshot {
        try await withMutation(at: path) {
            guard snapshot.editable else { throw GitFailure("Use a whole-file choice for this conflict.") }
            guard snapshot.fingerprint == (try await fingerprint(at: path, file: snapshot.file)) else { throw GitFailure("File or index changed outside Citadel. Your draft is preserved. Reload before saving.") }
            let target = try worktreeURL(at: path, file: snapshot.file)
            let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
            let normalized = snapshot.crlf ? result.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n") : result
            try Data(normalized.utf8).write(to: target, options: .atomic)
            if let permissions = attributes[.posixPermissions] { try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path) }
            return try await conflict(at: path, file: snapshot.file)
        }
    }
    public func chooseConflictVersion(at path: String, snapshot: ConflictSnapshot, stage: Int?) async throws -> ConflictSnapshot {
        try await withMutation(at: path) {
            guard snapshot.fingerprint == (try await fingerprint(at: path, file: snapshot.file)) else { throw GitFailure("File or index changed. Reload before choosing a version.") }
            let target = try worktreeURL(at: path, file: snapshot.file)
            if let stage, let version = snapshot.version(stage) {
                guard version.mode != "160000" else { throw GitFailure("Resolve the submodule in its own repository, then stage its path.") }
                if (try? target.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { try FileManager.default.removeItem(at: target) }
                if version.mode == "120000" {
                    if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                    guard let destination = String(data: version.data, encoding: .utf8) else { throw GitFailure("Invalid symlink target encoding.") }
                    try FileManager.default.createSymbolicLink(atPath: target.path, withDestinationPath: destination)
                } else {
                    try version.data.write(to: target, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: version.mode == "100755" ? 0o755 : 0o644], ofItemAtPath: target.path)
                }
            } else {
                if FileManager.default.fileExists(atPath: target.path) || (try? target.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { try FileManager.default.removeItem(at: target) }
            }
            return try await conflict(at: path, file: snapshot.file)
        }
    }
    public func markResolved(at path: String, snapshot: ConflictSnapshot) async throws {
        try await withMutation(at: path) {
            guard snapshot.fingerprint == (try await fingerprint(at: path, file: snapshot.file)) else { throw GitFailure("The result changed. Reload before marking resolved.") }
            if let result = snapshot.result, ConflictBlock.hasMarkers(result) { throw GitFailure("Conflict markers remain. Remove or resolve them before staging.") }
            try await run(path, ["add", "--", snapshot.file])
        }
    }
}
