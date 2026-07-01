import Foundation

// MARK: - LikeQueueWorker (Service)
// NOT a repository — it has no store, no cursor, no domain rows.
// It runs a behaviour: draining the LikeQueue to the network.
// This is the distinction between Service and Repository made concrete.
//
// Flow: dequeue → call API → on success remove from queue
//                          → on failure increment retry, back off, try again
//                          → after maxRetries → rollback optimistic update in store

public actor LikeQueueWorker {
    private let queue:      LikeQueue
    private let api:        LikeAPIClient
    private let store:      PostStore
    private let maxRetries: Int
    private var workerTask: Task<Void, Never>?

    public init(queue: LikeQueue, api: LikeAPIClient, store: PostStore, maxRetries: Int = 3) {
        self.queue      = queue
        self.api        = api
        self.store      = store
        self.maxRetries = maxRetries
    }

    // Call on app foreground / network reachability change.
    public func start() {
        guard workerTask == nil else { return }
        Log.worker.info("worker started (poll every 5s)")
        workerTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.drainOnce()
                try? await Task.sleep(for: .seconds(5))  // poll every 5s
            }
            Log.worker.info("worker loop exited (cancelled)")
        }
    }

    public func stop() {
        Log.worker.info("worker stopping")
        workerTask?.cancel()
        workerTask = nil
    }

    private func drainOnce() async {
        guard let intent = try? await queue.dequeue() else { return }

        await interval("LikeQueueWorker.drainOnce", Log.worker, "intent=\(intent.id) action=\(intent.action.rawValue) retry=\(intent.retryCount)") {
            do {
                switch intent.action {
                case .like:   try await api.like(postId: intent.postId)
                case .unlike: try await api.unlike(postId: intent.postId)
                }
                try? await queue.remove(id: intent.id)
                trace(Log.worker, "intent \(intent.id) drained OK")
            } catch {
                if intent.retryCount >= maxRetries {
                    // Give up — rollback the optimistic update in the store
                    Log.worker.error("intent \(intent.id, privacy: .public) exhausted retries; rolling back")
                    let rollbackLiked = intent.action == .unlike  // reverse the intent
                    let delta         = rollbackLiked ? 1 : -1
                    try? await store.updateLike(postId: intent.postId, isLiked: rollbackLiked, delta: delta)
                    try? await queue.remove(id: intent.id)
                } else {
                    trace(Log.worker, "intent \(intent.id) failed; incrementing retry")
                    try? await queue.incrementRetry(id: intent.id)
                }
            }
        }
    }
}
