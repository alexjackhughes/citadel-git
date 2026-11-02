import Foundation

private actor MutationGate {
    static let shared = MutationGate()
    private var active = Set<String>()
    private var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]
    func acquire(_ path: String) async {
        if active.insert(path).inserted { return }
        await withCheckedContinuation { waiting[path, default: []].append($0) }
    }
    func release(_ path: String) {
        if var queue = waiting[path], !queue.isEmpty {
            let next = queue.removeFirst(); waiting[path] = queue; next.resume()
        } else { active.remove(path); waiting.removeValue(forKey: path) }
    }
}
private enum MutationContext { @TaskLocal static var paths: Set<String> = [] }
extension GitRepository {
    func withMutation<T>(at path: String, _ body: () async throws -> T) async throws -> T {
        let key = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        if MutationContext.paths.contains(key) { return try await body() }
        await MutationGate.shared.acquire(key)
        do {
            try Task.checkCancellation()
            let result = try await MutationContext.$paths.withValue(MutationContext.paths.union([key])) { try await body() }
            await MutationGate.shared.release(key)
            return result
        } catch { await MutationGate.shared.release(key); throw error }
    }
}
