import Foundation

// MARK: - ImpressionTracker (Service)
// Batches postIds the user has scrolled past and flushes them to the backend.
// The backend uses these to update the "seen posts" log — powering the
// deduplication we discussed (server side, not client side).
//
// Fire-and-forget: if the flush fails, we drop it silently.
// This is not critical path — eventual delivery is fine.
// No store, no cursor, no domain rows → it's a Service, not a Repository.

public actor ImpressionTracker {
    private var pending:     Set<String> = []
    private var flushTask:   Task<Void, Never>?
    private let flushAfter:  Duration
    private let onFlush:     @Sendable ([String]) async -> Void

    public init(
        flushAfter: Duration = .seconds(3),
        onFlush: @escaping @Sendable ([String]) async -> Void
    ) {
        self.flushAfter = flushAfter
        self.onFlush    = onFlush
    }

    public func track(postId: String) {
        pending.insert(postId)
        trace(Log.impression, "tracked \(postId); \(pending.count) pending")
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: self?.flushAfter ?? .seconds(3))
            await self?.flush()
        }
    }

    private func flush() async {
        guard !pending.isEmpty else { flushTask = nil; return }
        let batch = Array(pending)
        pending.removeAll()
        flushTask = nil
        trace(Log.impression, "flushing batch of \(batch.count)")
        await onFlush(batch)   // fire and forget — caller hits POST /impressions
    }
}
