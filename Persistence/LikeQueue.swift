import Foundation

// MARK: - LikeQueue (outbox)
// Persists like/unlike intents so they survive app kill.
// The ViewModel writes here immediately on tap (fast, local-only).
// LikeQueueWorker drains these to the network asynchronously.
// This is the "offline-first like" mechanism — never lose a tap.

public protocol LikeQueue: Sendable {
    func enqueue(_ intent: LikeIntent) async throws
    func dequeue() async throws -> LikeIntent?
    func remove(id: String) async throws
    func incrementRetry(id: String) async throws
    func all() async throws -> [LikeIntent]
}

// In-memory implementation — in production replace with a SQLite/GRDB table
// (same pattern as PostStore: just add FetchableRecord/PersistableRecord).

public actor InMemoryLikeQueue: LikeQueue {
    private var queue: [String: LikeIntent] = [:]   // id → intent
    private var insertOrder: [String]        = []

    public init() {}

    public func enqueue(_ intent: LikeIntent) async throws {
        // If an opposite intent is pending for this post, cancel them out.
        if let existing = queue.values.first(where: { $0.postId == intent.postId }) {
            queue[existing.id] = nil
            insertOrder.removeAll { $0 == existing.id }
        }
        queue[intent.id] = intent
        insertOrder.append(intent.id)
    }

    public func dequeue() async throws -> LikeIntent? {
        guard let id = insertOrder.first, let intent = queue[id] else { return nil }
        return intent
    }

    public func remove(id: String) async throws {
        queue[id] = nil
        insertOrder.removeAll { $0 == id }
    }

    public func incrementRetry(id: String) async throws {
        queue[id]?.retryCount += 1
    }

    public func all() async throws -> [LikeIntent] {
        insertOrder.compactMap { queue[$0] }
    }
}
