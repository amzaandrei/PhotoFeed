import Foundation

// MARK: - FeedRepository protocol
// What the ViewModel talks to. Notice what is NOT in this protocol:
//   • No cursor — the ViewModel cannot see or touch it
//   • No Page<Post> — data reaches the VM only via observation
//   • No APIClient — the VM doesn't know the network exists
//   • No store type — GRDB vs in-memory is invisible upstairs
//
// The three things the VM CAN do:
//   • Observe the SSOT stream (read path)
//   • Ask for the next page (intent — returns Void)
//   • Ask for a refresh (intent — returns Void)

public protocol FeedRepository: Sendable {
    func observePosts() async -> AsyncThrowingStream<[Post], Error>
    func loadNextPage() async throws
    func refresh() async throws
    var hasMorePages: Bool { get async }
}

// MARK: - DefaultFeedRepository
// An actor: cursor state is concurrency-safe by construction.
// No locks, no DispatchQueue juggling, no performAndWait.
// Swift concurrency gives us this for free.

public actor DefaultFeedRepository: FeedRepository {
    private let api:      FeedAPIClient
    private let store:    PostStore
    private let pageSize: Int

    // Cursor lives here — invisible to everything above this box.
    private var cursor:     Cursor?
    private var reachedEnd: Bool = false
    private var isFetching: Bool = false   // prevents double-fire during scroll

    public init(api: FeedAPIClient, store: PostStore, pageSize: Int = 10) {
        self.api      = api
        self.store    = store
        self.pageSize = pageSize
    }

    public var hasMorePages: Bool { !reachedEnd }

    // The ViewModel subscribes to this ONCE on appear.
    // Every write to the store (from any source) re-emits here automatically.
    // This is the SSOT observation — the purple dashed arrow on the diagram.
    public func observePosts() async -> AsyncThrowingStream<[Post], Error> {
        trace(Log.repository, "observePosts (entered repo actor)")
        return await store.observeAll()
    }

    // Intent: fetch next page, write to store, advance cursor.
    // Returns Void — data reaches the VM via observation, not this return value.
    public func loadNextPage() async throws {
        guard !reachedEnd, !isFetching else {
            trace(Log.repository, "loadNextPage skipped (reachedEnd=\(reachedEnd) isFetching=\(isFetching))")
            return
        }
        isFetching = true
        defer { isFetching = false }

        try await interval("FeedRepository.loadNextPage", Log.repository, "cursor=\(cursor?.value ?? "nil")") {
            let page = try await api.fetchFeed(after: cursor, limit: pageSize)
            trace(Log.repository, "fetched \(page.items.count) posts; writing to store")
            try await store.upsert(page.items)
            cursor     = page.nextCursor
            reachedEnd = page.nextCursor == nil
            trace(Log.repository, "cursor advanced to \(cursor?.value ?? "nil"); reachedEnd=\(reachedEnd)")
        }
    }

    // Intent: reset pagination, replace store contents from page 1.
    // This is pull-to-refresh. Wipes and reloads — does NOT merge/append.
    public func refresh() async throws {
        guard !isFetching else {
            trace(Log.repository, "refresh skipped (isFetching)")
            return
        }
        isFetching = true
        defer { isFetching = false }

        try await interval("FeedRepository.refresh", Log.repository) {
            cursor     = nil
            reachedEnd = false
            let page   = try await api.fetchFeed(after: nil, limit: pageSize)
            trace(Log.repository, "refresh fetched \(page.items.count) posts; replacing store")
            try await store.replaceAll(page.items)
            cursor     = page.nextCursor
            reachedEnd = page.nextCursor == nil
        }
    }
}
