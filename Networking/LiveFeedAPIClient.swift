import Foundation

// MARK: - LiveFeedAPIClient (production)
// Real network client behind the same FeedAPIClient protocol the repository
// already depends on. Used only in the .production environment; previews, tests,
// and the .testing environment use MockFeedAPIClient. Swapping one for the other
// is a single line in AppComposition — nothing upstream changes.
//
// Wire format: GET {base}/feed?limit={}&after={} → { "posts": [...], "nextCursor": "..."? }

public struct LiveFeedAPIClient: FeedAPIClient {
    private let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func fetchFeed(after cursor: Cursor?, limit: Int) async throws -> Page<Post> {
        try await interval("LiveFeedAPIClient.fetchFeed", Log.repository, "limit=\(limit)") {
            var components = URLComponents(
                url: baseURL.appendingPathComponent("feed"),
                resolvingAgainstBaseURL: false
            )!
            var query = [URLQueryItem(name: "limit", value: String(limit))]
            if let cursor { query.append(URLQueryItem(name: "after", value: cursor.value)) }
            components.queryItems = query

            let (data, response) = try await session.data(from: components.url!)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                Log.repository.error("fetchFeed bad response")
                throw URLError(.badServerResponse)
            }
            let decoded = try JSONDecoder.photoFeed.decode(FeedResponse.self, from: data)
            trace(Log.repository, "decoded \(decoded.posts.count) posts, nextCursor=\(decoded.nextCursor ?? "nil")")
            return Page(items: decoded.posts, nextCursor: decoded.nextCursor.map(Cursor.init))
        }
    }

    private struct FeedResponse: Decodable {
        let posts: [Post]
        let nextCursor: String?
    }
}

// MARK: - LiveLikeAPIClient (production)
// Matches: POST {base}/posts/{id}/like → 2xx ;  DELETE {base}/posts/{id}/like → 2xx

public struct LiveLikeAPIClient: LikeAPIClient {
    private let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func like(postId: String)   async throws { try await send(postId: postId, method: "POST") }
    public func unlike(postId: String) async throws { try await send(postId: postId, method: "DELETE") }

    private func send(postId: String, method: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("posts/\(postId)/like"))
        request.httpMethod = method
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
}

// MARK: - Shared decoder

extension JSONDecoder {
    /// ISO-8601 dates, matching the backend's `timestamp` encoding.
    static var photoFeed: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
