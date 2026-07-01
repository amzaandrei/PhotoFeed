import Foundation

// MARK: - PostStore protocol
// Table gateway for Post rows. Dumb and per-entity — no business logic here.
// The SSOT contract: observeAll() emits the full snapshot on EVERY write,
// from any writer (network sync, like update, pull-to-refresh, another screen).
// The ViewModel subscribes once and never has to manually coordinate updates.

public protocol PostStore: Sendable {
    func upsert(_ posts: [Post]) async throws
    func updateLike(postId: String, isLiked: Bool, delta: Int) async throws
    func replaceAll(_ posts: [Post]) async throws
    func observeAll() async -> AsyncThrowingStream<[Post], Error>
    func count() async throws -> Int
}

// MARK: - InMemoryPostStore
// Used in SwiftUI Previews, unit tests, and when running without GRDB.
// Mirrors how GRDB's ValueObservation behaves: every mutation pushes the
// full current snapshot to all active observers simultaneously.

public actor InMemoryPostStore: PostStore {
    private var byId:   [String: Post] = [:]
    private var order:  [String]       = []
    private var sinks:  [UUID: AsyncThrowingStream<[Post], Error>.Continuation] = [:]

    public init(seed: [Post] = []) {
        for post in seed { byId[post.id] = post; order.append(post.id) }
    }

    private var snapshot: [Post] { order.compactMap { byId[$0] } }

    private func broadcast() {
        let current = snapshot
        trace(Log.store, "broadcast \(current.count) posts to \(sinks.count) observer(s)")
        sinks.values.forEach { $0.yield(current) }
    }

    public func upsert(_ posts: [Post]) async throws {
        trace(Log.store, "upsert \(posts.count) posts (entered actor)")
        for p in posts {
            if byId[p.id] == nil { order.append(p.id) }
            byId[p.id] = p
        }
        broadcast()
    }

    public func updateLike(postId: String, isLiked: Bool, delta: Int) async throws {
        trace(Log.store, "updateLike post=\(postId) liked=\(isLiked) delta=\(delta)")
        guard var p = byId[postId] else { return }
        p.isLikedByMe = isLiked
        p.likesCount  = max(0, p.likesCount + delta)
        byId[postId]  = p
        broadcast()
    }

    public func replaceAll(_ posts: [Post]) async throws {
        trace(Log.store, "replaceAll with \(posts.count) posts")
        byId  = Dictionary(uniqueKeysWithValues: posts.map { ($0.id, $0) })
        order = posts.map(\.id)
        broadcast()
    }

    public func observeAll() async -> AsyncThrowingStream<[Post], Error> {
        AsyncThrowingStream { continuation in
            let id = UUID()
            sinks[id] = continuation
            trace(Log.store, "new observer \(id.uuidString.prefix(8)); now \(sinks.count) total")
            continuation.yield(snapshot)          // emit current state immediately
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSink(id) }
            }
        }
    }

    private func removeSink(_ id: UUID) {
        sinks[id] = nil
        trace(Log.store, "observer \(id.uuidString.prefix(8)) terminated; \(sinks.count) remain")
    }

    public func count() async throws -> Int { byId.count }
}

// MARK: - GRDBPostStore (production)
// The real SQLite-backed store lives in GRDBPostStore.swift. It implements this
// exact protocol, so the repository above it cannot tell which store it's using.
// AppComposition picks InMemoryPostStore for .testing and GRDBPostStore for
// .production — that single swap is the whole production/testing schema split.
