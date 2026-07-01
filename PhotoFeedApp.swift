import SwiftUI

// MARK: - PhotoFeedApp
// The app shell. All dependency wiring is delegated to AppComposition, which
// builds the graph for the resolved AppEnvironment:
//
//   .production → GRDBPostStore (on-disk, indexed schema) + LiveFeedAPIClient + lifecycle logging
//   .testing    → InMemoryPostStore (ephemeral schema)    + MockFeedAPIClient + verbose concurrency traces + signposts
//
// Pick the environment with the PHOTOFEED_ENV launch variable (or DEBUG/Release
// default). See App/AppEnvironment.swift.

@main
struct PhotoFeedApp: App {
    private let graph = AppComposition.make(environment: .current)

    var body: some Scene {
        WindowGroup {
            FeedView(viewModel: graph.feedViewModel)
                .task {
                    // Start the background outbox worker.
                    await graph.likeWorker.start()
                }
        }
    }
}
