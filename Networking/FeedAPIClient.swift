import Foundation

// MARK: - FeedAPIClient
// Matches: GET /feed?limit={}&after={} → { posts: [Post], nextCursor: String? }
// The Repository depends on this protocol, never on a concrete URLSession/Alamofire
// client, so it can be swapped for MockFeedAPIClient in tests and previews.

public protocol FeedAPIClient: Sendable {
    func fetchFeed(after cursor: Cursor?, limit: Int) async throws -> Page<Post>
}

// MARK: - LikeAPIClient
// Matches: POST /posts/{id}/like → 204
//          DELETE /posts/{id}/like → 204
// Called by LikeQueueWorker when draining the outbox, not directly by the VM.

public protocol LikeAPIClient: Sendable {
    func like(postId: String) async throws
    func unlike(postId: String) async throws
}

// MARK: - Mock implementations (used for previews, tests, and running without a backend)

public struct MockFeedAPIClient: FeedAPIClient {
    private let catalogue: [Post]
    private let delay: Duration

    public init(delay: Duration = .milliseconds(300)) {
        self.catalogue = Self.makeCatalogue()
        self.delay = delay
    }

    public func fetchFeed(after cursor: Cursor?, limit: Int) async throws -> Page<Post> {
        try? await Task.sleep(for: delay)
        let start = cursor.flatMap { Int($0.value) } ?? 0
        let end   = min(start + limit, catalogue.count)
        guard start < catalogue.count else { return Page(items: [], nextCursor: nil) }
        let slice = Array(catalogue[start..<end])
        let next: Cursor? = end < catalogue.count ? Cursor(String(end)) : nil
        return Page(items: slice, nextCursor: next)
    }

    private static func makeCatalogue() -> [Post] {
        let users = [
            ("user_andrei",  "Andrei",  "https://i.pravatar.cc/150?u=andrei"),
            ("user_maria",   "Maria",   "https://i.pravatar.cc/150?u=maria"),
            ("user_stefan",  "Stefan",  "https://i.pravatar.cc/150?u=stefan"),
            ("user_elena",   "Elena",   "https://i.pravatar.cc/150?u=elena"),
            ("user_mihai",   "Mihai",   "https://i.pravatar.cc/150?u=mihai"),
        ]
        let captions = [
            "Morning session. Clean pull. 💪",
            "Zürich from above. Worth the climb.",
            "Best coffee in the Altstadt.",
            "Rest day reading. Finally.",
            "PR day. 140kg clean. Let's go.",
            "Trail run in the Alps. Legs done.",
            "Post-workout meal. Protein first.",
            "New Canyon Grail arrived. 🚵",
            "Olympic lifting seminar day 2.",
            "Sunset from Üetliberg.",
            "Morning mobility routine.",
            "CrossFit open prep. Week 3.",
            "Front squat depth improving.",
            "Weekend gravel ride. 80km done.",
            "Recovery shake and chill.",
            "Snatch technique finally clicking.",
            "Hiking the Rigi. Perfect day.",
            "Team training session. Good crew.",
            "Powerlifting meet prep begins.",
            "Late night coding + espresso.",
        ]
        let photos = (1...20).map { "https://picsum.photos/seed/post\($0)/600/600" }

        return (0..<20).map { i in
            let u = users[i % users.count]
            let preview = [
                PreviewComment(id: "c\(i)a", authorUsername: users[(i+1) % users.count].1, text: "Looking strong! 🔥"),
                PreviewComment(id: "c\(i)b", authorUsername: users[(i+2) % users.count].1, text: "Goals 💯"),
            ]
            return Post(
                id:               "post-\(i)",
                authorId:         u.0,
                authorUsername:   u.1,
                authorAvatarUrl:  u.2,
                photoUrl:         photos[i],
                caption:          captions[i],
                location:         i % 3 == 0 ? "Zürich, Switzerland" : nil,
                timestamp:        Date().addingTimeInterval(Double(-i * 3600)),
                likesCount:       Int.random(in: 12...2400),
                commentsCount:    Int.random(in: 2...120),
                isLikedByMe:      i % 5 == 0,
                previewComments:  preview
            )
        }
    }
}

public struct MockLikeAPIClient: LikeAPIClient {
    public init() {}
    public func like(postId: String)   async throws { try? await Task.sleep(for: .milliseconds(200)) }
    public func unlike(postId: String) async throws { try? await Task.sleep(for: .milliseconds(200)) }
}
