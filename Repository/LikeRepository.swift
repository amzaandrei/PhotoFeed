import Foundation

// MARK: - LikeRepository
// Separate from FeedRepository because liking is its own data concern.
// Owns: optimistic store update + outbox write in one atomic step.
// The ViewModel calls toggle(post:) and gets instant local feedback
// via the PostStore observation — no waiting for the network.

public protocol LikeRepository: Sendable {
    func toggle(post: Post) async throws
}

public actor DefaultLikeRepository: LikeRepository {
    private let store: PostStore
    private let queue: LikeQueue

    public init(store: PostStore, queue: LikeQueue) {
        self.store = store
        self.queue = queue
    }

    // 1. Flip isLikedByMe and ±1 likesCount in the store immediately
    //    → PostStore broadcasts → ViewModel receives → heart animates
    //    This all happens before a single network byte is sent.
    //
    // 2. Enqueue the intent to the persisted outbox.
    //    LikeQueueWorker picks it up and drains it to the API.
    //    If offline, it stays in the queue until connectivity returns.
    //
    // If the network eventually rejects (e.g. 401), the Worker calls
    // store.updateLike(postId:isLiked:delta:) to roll back.

    public func toggle(post: Post) async throws {
        let nowLiked = !post.isLikedByMe
        let delta    = nowLiked ? 1 : -1
        let action   = nowLiked ? LikeIntent.Action.like : .unlike

        try await interval("LikeRepository.toggle", Log.like, "post=\(post.id) -> \(action.rawValue)") {
            // Step 1 — optimistic update (instant)
            try await store.updateLike(postId: post.id, isLiked: nowLiked, delta: delta)
            trace(Log.like, "optimistic store update done; enqueuing intent")

            // Step 2 — persist intent to outbox
            let intent = LikeIntent(postId: post.id, action: action)
            try await queue.enqueue(intent)
            trace(Log.like, "intent \(intent.id) enqueued")
        }
    }
}
