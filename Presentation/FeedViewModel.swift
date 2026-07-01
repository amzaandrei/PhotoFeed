import Foundation
import Combine

// MARK: - FeedViewModel
// Presentation logic ONLY. It depends on protocols, never on concrete types.
// Inject MockFeedAPIClient + InMemoryPostStore in previews/tests
// and the real implementations in production — nothing here changes.
//
// What it NEVER knows about:
//   • The cursor (lives in FeedRepository actor)
//   • Whether data came from GRDB or the network (SSOT hides this)
//   • Whether GRDB or InMemoryStore is underneath
//   • The LikeQueue (LikeRepository handles the outbox write)
//
// What it DOES own:
//   • @Published state the View binds to
//   • The decision of WHEN to trigger intents (scroll position, appear, pull)
//   • Error formatting for display

@MainActor
public final class FeedViewModel: ObservableObject {
    @Published public private(set) var posts:        [Post]  = []
    @Published public private(set) var isLoading:    Bool    = false
    @Published public private(set) var isRefreshing: Bool    = false
    @Published public private(set) var errorMessage: String? = nil

    private let feedRepo:       FeedRepository
    private let likeRepo:       LikeRepository
    private let impressions:    ImpressionTracker
    private var observationTask: Task<Void, Never>?

    public init(
        feedRepo:    FeedRepository,
        likeRepo:    LikeRepository,
        impressions: ImpressionTracker
    ) {
        self.feedRepo    = feedRepo
        self.likeRepo    = likeRepo
        self.impressions = impressions
    }

    // Call from .task {} on the root view.
    // Starts the SSOT observation and loads page 1.
    public func onAppear() {
        trace(Log.viewModel, "onAppear")
        startObserving()
        Task { await loadMore() }
    }

    // Infinite scroll trigger — called from .onAppear on the last visible cell.
    public func loadMore() async {
        guard !isLoading, await feedRepo.hasMorePages else {
            trace(Log.viewModel, "loadMore skipped (isLoading=\(isLoading))")
            return
        }
        isLoading = true
        defer { isLoading = false }
        do    { try await feedRepo.loadNextPage() }
        catch {
            Log.viewModel.error("loadMore failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    // Pull-to-refresh — replaces feed from top, resets cursor.
    public func refresh() async {
        trace(Log.viewModel, "refresh")
        isRefreshing = true
        defer { isRefreshing = false }
        do    { try await feedRepo.refresh() }
        catch {
            Log.viewModel.error("refresh failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    // Like tap — optimistic UI via LikeRepository.
    // The heart flips before the network call starts.
    public func toggleLike(post: Post) {
        trace(Log.viewModel, "toggleLike post=\(post.id) (spawning detached intent)")
        Task {
            do    { try await likeRepo.toggle(post: post) }
            catch {
                Log.viewModel.error("toggleLike failed: \(error.localizedDescription, privacy: .public)")
                errorMessage = error.localizedDescription
            }
        }
    }

    // Called when a cell becomes visible — feeds the ImpressionTracker.
    public func didSeePost(_ post: Post) {
        Task { await impressions.track(postId: post.id) }
    }

    deinit { observationTask?.cancel() }

    // MARK: Private

    private func startObserving() {
        guard observationTask == nil else { return }
        observationTask = Task { [weak self] in
            guard let self else { return }
            // This stream re-emits on EVERY write to the PostStore —
            // from network pages, from like updates, from refresh.
            // The ViewModel doesn't care who wrote; it just renders.
            let stream = await self.feedRepo.observePosts()
            trace(Log.viewModel, "observation task running; awaiting store snapshots")
            do {
                for try await updatedPosts in stream {
                    // Resumed on the @MainActor — note the `main` context in the
                    // trace vs the `bg` actor hops above it.
                    trace(Log.viewModel, "snapshot received: \(updatedPosts.count) posts -> assigning @Published")
                    self.posts = updatedPosts
                }
            } catch {
                Log.viewModel.error("observation stream failed: \(error.localizedDescription, privacy: .public)")
                self.errorMessage = error.localizedDescription
            }
        }
    }
}
