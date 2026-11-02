import Foundation
import CryptoKit

public struct SourceFingerprint: Equatable, Sendable {
    public let index: String
    public let working: String
}
public enum DiffLineKind: String, Sendable { case context, addition, deletion, header, metadata }
public struct DiffLine: Identifiable, Sendable {
    public let id: Int
    public let text: String
    public let kind: DiffLineKind
    public let oldNumber: Int?
    public let newNumber: Int?
    public let hunk: Int?
}
public struct DiffHunk: Identifiable, Sendable {
    public let id: Int
    public let header: String
    public var complete: Bool
    public var lineIDs: [Int]
}
public struct DiffPage: Sendable {
    public let lines: [DiffLine]
    public let hunks: [DiffHunk]
    public let complete: Bool
}

// The raw diff remains on disk. Only requested display pages are decoded.
public actor DiffDocument {
    public nonisolated let id = UUID()
    public nonisolated let file: String
    public nonisolated let staged: Bool
    public nonisolated let fingerprint: SourceFingerprint?
    public nonisolated let partialStagingAllowed: Bool
    private let output: GitOutput
    private let reader: FileHandle
    private var buffer = Data()
    private var eof = false
    private var counter = 0
    private var old = 0, new = 0
    private var hunks: [DiffHunk] = []
    private var headers: [String] = []
    private var rawHunks: [[Range<UInt64>]] = []
    private var byteOffset: UInt64 = 0
    private var lineRange: Range<UInt64> = 0..<0
    private var invalidEncoding = false
    private var rawIDs: [[Int]] = []
    private var currentHunk: Int?

    init(output: GitOutput, file: String, staged: Bool, fingerprint: SourceFingerprint?, partial: Bool) throws {
        self.output = output; self.file = file; self.staged = staged
        self.fingerprint = fingerprint; partialStagingAllowed = partial
        reader = try FileHandle(forReadingFrom: output.stdout)
    }
    deinit { try? reader.close() }
    private func nextLine() throws -> String? {
        while true {
            if let end = buffer.firstIndex(of: 10) {
                let data = Data(buffer.prefix(upTo: end))
                let length = data.count + 1
                lineRange = byteOffset..<(byteOffset + UInt64(length)); byteOffset += UInt64(length)
                buffer.removeSubrange(...end)
                if String(data: data, encoding: .utf8) == nil { invalidEncoding = true }
                return String(decoding: data, as: UTF8.self)
            }
            if eof {
                guard !buffer.isEmpty else { return nil }
                lineRange = byteOffset..<(byteOffset + UInt64(buffer.count)); byteOffset += UInt64(buffer.count)
                if String(data: buffer, encoding: .utf8) == nil { invalidEncoding = true }
                let line = String(decoding: buffer, as: UTF8.self); buffer.removeAll(); return line
            }
            let chunk = try reader.read(upToCount: 65_536) ?? Data()
            if chunk.isEmpty { eof = true } else { buffer.append(chunk) }
        }
    }
    public func nextPage(count: Int = 400) throws -> DiffPage {
        var lines: [DiffLine] = []
        while lines.count < count {
            try Task.checkCancellation()
            guard let line = try nextLine() else {
                if let currentHunk { hunks[currentHunk].complete = true }
                return DiffPage(lines: lines, hunks: hunks, complete: true)
            }
            let id = counter; counter += 1
            var kind = DiffLineKind.metadata, before: Int?, after: Int?
            if line.hasPrefix("@@ ") {
                if let currentHunk { hunks[currentHunk].complete = true }
                let fields = line.split(separator: " ")
                if fields.count >= 3 {
                    old = Int(fields[1].dropFirst().split(separator: ",")[0]) ?? 0
                    new = Int(fields[2].dropFirst().split(separator: ",")[0]) ?? 0
                }
                currentHunk = hunks.count
                hunks.append(DiffHunk(id: hunks.count, header: line, complete: false, lineIDs: []))
                rawHunks.append([lineRange]); rawIDs.append([id]); kind = .header
            } else if let hunk = currentHunk {
                rawHunks[hunk].append(lineRange); rawIDs[hunk].append(id)
                if line.hasPrefix("+") { kind = .addition; after = new; new += 1 }
                else if line.hasPrefix("-") { kind = .deletion; before = old; old += 1 }
                else if line.hasPrefix(" ") { kind = .context; before = old; after = new; old += 1; new += 1 }
                if kind == .addition || kind == .deletion { hunks[hunk].lineIDs.append(id) }
            } else { headers.append(line) }
            let display = line.count > 4_000 ? String(line.prefix(4_000)) + " … [long line; full content retained]" : line
            lines.append(DiffLine(id: id, text: display, kind: kind, oldNumber: before, newNumber: after, hunk: currentHunk))
        }
        return DiffPage(lines: lines, hunks: hunks, complete: false)
    }

    // Build a patch that transforms the current index into the user's selection.
    // In reverse mode additions/deletions are swapped before selecting lines.
    public func patch(selected: Set<Int>) throws -> Data {
        guard partialStagingAllowed, !invalidEncoding, !selected.isEmpty else { throw GitFailure("Select changed text lines first.") }
        let involved = hunks.filter { !selected.isDisjoint(with: $0.lineIDs) }
        guard !involved.isEmpty, involved.allSatisfy(\.complete) else { throw GitFailure("Load the complete hunk before staging it.") }
        let quotedA = Self.quote("a/" + file), quotedB = Self.quote("b/" + file)
        var result = "diff --git \(quotedA) \(quotedB)\n--- \(quotedA)\n+++ \(quotedB)\n"
        // For a new file, a selected patch creates only the selected contents.
        if !staged && headers.contains("--- /dev/null") {
            result = "diff --git \(quotedA) \(quotedB)\n\(headers.first(where: { $0.hasPrefix("new file mode ") }) ?? "new file mode 100644")\n--- /dev/null\n+++ \(quotedB)\n"
        }
        var cumulativeDelta = 0
        for hunk in involved {
            let handle = try FileHandle(forReadingFrom: output.stdout)
            defer { try? handle.close() }
            let raw = try rawHunks[hunk.id].map { range -> String in
                try handle.seek(toOffset: range.lowerBound)
                var bytes = try handle.read(upToCount: Int(range.count)) ?? Data()
                if bytes.last == 10 { bytes.removeLast() }
                return String(decoding: bytes, as: UTF8.self)
            }
            let ids = rawIDs[hunk.id]
            let fields = raw[0].split(separator: " ")
            let sourceToken = staged ? fields[2] : fields[1]
            let start = Int(sourceToken.dropFirst().split(separator: ",")[0]) ?? 0
            var body: [String] = [], oldCount = 0, newCount = 0
            var previousIncluded = false
            for i in 1..<raw.count {
                let line = raw[i]
                if line.hasPrefix("\\") { if previousIncluded { body.append(line) }; continue }
                guard let original = line.first, " +-".contains(original) else { continue }
                let sign: Character = staged ? (original == "+" ? "-" : original == "-" ? "+" : original) : original
                let chosen = selected.contains(ids[i])
                if sign == "+" && !chosen { previousIncluded = false; continue }
                let outputSign: Character = sign == "-" && !chosen ? " " : sign
                body.append(String(outputSign) + line.dropFirst()); previousIncluded = true
                if outputSign != "+" { oldCount += 1 }
                if outputSign != "-" { newCount += 1 }
            }
            let oldStart = oldCount == 0 ? max(0, start) : max(1, start)
            let newStart = newCount == 0 ? max(0, oldStart + cumulativeDelta - 1) : max(1, oldStart + cumulativeDelta)
            result += "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@\n" + body.joined(separator: "\n") + "\n"
            cumulativeDelta += newCount - oldCount
        }
        return Data(result.utf8)
    }
    static func quote(_ path: String) -> String {
        "\"" + path.utf8.map { byte -> String in
            if byte == 34 { return "\\\"" }; if byte == 92 { return "\\\\" }
            if byte < 32 || byte >= 127 { return String(format: "\\%03o", byte) }
            return String(UnicodeScalar(byte))
        }.joined() + "\""
    }
}

extension GitRepository {
    public func fingerprint(at path: String, file: String) async throws -> SourceFingerprint {
        guard !file.hasPrefix("/"), !file.components(separatedBy: "/").contains("..") else { throw GitFailure("Invalid repository path.") }
        let index = try await run(path, ["ls-files", "--stage", "-z", "--", file])
        let url = try worktreeURL(at: path, file: file)
        var hasher = SHA256()
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let type = attributes?[.type] as? FileAttributeType
        hasher.update(data: Data("\(type?.rawValue ?? "missing"):\(attributes?[.posixPermissions] ?? "none")\n".utf8))
        if type == .typeSymbolicLink {
            hasher.update(data: Data((try FileManager.default.destinationOfSymbolicLink(atPath: url.path)).utf8))
        } else if let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            while let bytes = try handle.read(upToCount: 65_536), !bytes.isEmpty { try Task.checkCancellation(); hasher.update(data: bytes) }
        }
        return SourceFingerprint(index: index, working: hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }
    public func diffDocument(at path: String, file: String, staged: Bool = false, commit: String? = nil) async throws -> DiffDocument {
        guard !file.isEmpty, !file.hasPrefix("/"), !file.components(separatedBy: "/").contains("..") else { throw GitFailure("Invalid repository path.") }
        let before = commit == nil ? try await fingerprint(at: path, file: file) : nil
        let args: [String]
        if let commit {
            guard commit.count == 40 || commit.count == 64, commit.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw GitFailure("Invalid commit.") }
            args = ["show", "--format=", "--first-parent", "--diff-merges=first-parent", "--no-ext-diff", "--no-textconv", commit, "--", file]
        } else { args = ["diff"] + (staged ? ["--cached"] : []) + ["--no-ext-diff", "--no-textconv", "--", file] }
        var output = try await GitProcess.execute(at: path, arguments: args)
        let size = (try FileManager.default.attributesOfItem(atPath: output.stdout.path)[.size] as? NSNumber)?.intValue ?? 0
        let index = before?.index ?? ""
        if size == 0 && commit == nil && !staged && index.isEmpty {
            let status = try await run(path, ["status", "--porcelain=v1", "-z", "--", file])
            if status.hasPrefix("?? ") {
                let target = URL(fileURLWithPath: path).appendingPathComponent(file)
                let root = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                guard target.resolvingSymlinksInPath().path.hasPrefix(root + "/") else { throw GitFailure("This link points outside the repository.") }
                output = try await GitProcess.execute(at: path, arguments: ["diff", "--no-index", "--no-ext-diff", "--no-textconv", "--", "/dev/null", target.path], allowFailure: true)
                guard output.status <= 1 else { throw GitFailure("Cannot preview this file.") }
            }
        }
        if let before, before != (try await fingerprint(at: path, file: file)) { throw GitFailure("This file changed while loading. Select it again to refresh.") }
        let status = commit == nil ? try await run(path, ["status", "--porcelain=v1", "-z", "--", file]) : ""
        let modeSupported = ((try? FileManager.default.attributesOfItem(atPath: URL(fileURLWithPath: path).appendingPathComponent(file).path)[.type]) as? FileAttributeType) != .typeSymbolicLink && (index.isEmpty || index.split(separator: "\0").allSatisfy { $0.hasPrefix("100644 ") || $0.hasPrefix("100755 ") })
        let partial = commit == nil && modeSupported && !status.prefix(2).contains("R") && !status.prefix(2).contains("C") && !status.prefix(2).contains("U") && !status.hasPrefix("AA") && !status.hasPrefix("DD")
        return try DiffDocument(output: output, file: file, staged: staged, fingerprint: before, partial: partial)
    }
    public func applySelection(at path: String, document: DiffDocument, selected: Set<Int>) async throws {
        try await withMutation(at: path) {
        guard let before = document.fingerprint, before == (try await fingerprint(at: path, file: document.file)) else { throw GitFailure("The file or index changed. Refresh and select the lines again.") }
        let patch = try await document.patch(selected: selected)
        try await run(path, ["apply", "--cached", "--check", "--whitespace=nowarn", "-"], input: patch)
        guard before == (try await fingerprint(at: path, file: document.file)) else { throw GitFailure("The file or index changed. Refresh and select the lines again.") }
        try await run(path, ["apply", "--cached", "--whitespace=nowarn", "-"], input: patch)
            }
    }
}
