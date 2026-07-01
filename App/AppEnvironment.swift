import Foundation

// MARK: - AppEnvironment
// One switch that selects the entire runtime profile. Production and testing get
// genuinely different infrastructure — a different persistence schema, a
// different API, and a different logging verbosity — but everything ABOVE the
// composition root is identical. That's the dependency-inversion payoff: the app
// is reconfigured from a single enum, no other file changes.
//
//   .production → GRDBPostStore (on-disk, indexed schema) + LiveFeedAPIClient   + lifecycle logging
//   .testing    → InMemoryPostStore (ephemeral schema)    + MockFeedAPIClient   + verbose concurrency traces + signposts

public enum AppEnvironment: String, Sendable {
    case production
    case testing

    /// Resolution order:
    ///   1. Running under XCTest                       → .testing
    ///   2. Launch env `PHOTOFEED_ENV=production|testing` → that value
    ///   3. DEBUG build                                → .testing  (runs offline, verbose)
    ///   4. Release build                              → .production
    public static var current: AppEnvironment {
        if NSClassFromString("XCTestCase") != nil { return .testing }
        if let raw = ProcessInfo.processInfo.environment["PHOTOFEED_ENV"],
           let env = AppEnvironment(rawValue: raw.lowercased()) {
            return env
        }
        #if DEBUG
        return .testing
        #else
        return .production
        #endif
    }

    /// Testing emits the per-hop concurrency traces and verbose signpost detail.
    /// Production keeps only lifecycle/error logging.
    public var isVerboseLogging: Bool { self == .testing }
}

// MARK: - AppComposition
// The composition root. The ONLY place that names concrete types. Given an
// environment it builds the whole graph and hands back exactly what the App
// scene needs.

public enum AppComposition {

    public struct Graph {
        public let feedViewModel: FeedViewModel
        public let likeWorker: LikeQueueWorker
        public let environment: AppEnvironment
    }

    /// Build the dependency graph for `environment`. The GRDB store can fail to
    /// open (disk full, permissions); rather than crash the app we log and fall
    /// back to the in-memory store, so the feed still works.
    ///
    /// `@MainActor` because it constructs the main-actor-isolated `FeedViewModel`.
    /// It's called from the (main-actor) `App`, so this is free.
    @MainActor
    public static func make(environment: AppEnvironment = .current) -> Graph {
        Log.isVerbose = environment.isVerboseLogging
        Log.app.notice("Booting PhotoFeed — environment=\(environment.rawValue, privacy: .public), verbose=\(environment.isVerboseLogging)")

        // --- environment-specific infrastructure ---
        let store:   PostStore
        let feedApi: FeedAPIClient
        let likeApi: LikeAPIClient

        switch environment {
        case .production:
            let baseURL = URL(string: "https://api.photofeed.example.com")!
            feedApi = LiveFeedAPIClient(baseURL: baseURL)
            likeApi = LiveLikeAPIClient(baseURL: baseURL)
            do {
                store = try GRDBPostStore(configuration: .production())
                Log.db.notice("Persistence: GRDBPostStore (on-disk, production schema)")
            } catch {
                Log.db.error("GRDB open failed: \(error.localizedDescription, privacy: .public). Falling back to InMemoryPostStore.")
                store = InMemoryPostStore()
            }

        case .testing:
            feedApi = MockFeedAPIClient()
            likeApi = MockLikeAPIClient()
            store   = InMemoryPostStore()
            Log.db.info("Persistence: InMemoryPostStore (ephemeral testing schema)")
        }

        // --- layers that are identical across environments ---
        let queue:    LikeQueue = InMemoryLikeQueue()
        let feedRepo  = DefaultFeedRepository(api: feedApi, store: store, pageSize: 10)
        let likeRepo  = DefaultLikeRepository(store: store, queue: queue)
        let worker    = LikeQueueWorker(queue: queue, api: likeApi, store: store)
        let tracker   = ImpressionTracker { ids in
            Log.impression.info("flushing \(ids.count) seen posts")
        }
        let viewModel = FeedViewModel(feedRepo: feedRepo, likeRepo: likeRepo, impressions: tracker)

        return Graph(feedViewModel: viewModel, likeWorker: worker, environment: environment)
    }
}
