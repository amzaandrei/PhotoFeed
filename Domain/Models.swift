import Foundation

// MARK: - Core domain models
// Framework-free. No SwiftUI, no GRDB imports here.
// Persistence conformances are added via extensions in the persistence layer.

public struct Post: Identifiable, Equatable, Codable, Sendable {
    public let id: String
    public let authorId: String
    public let authorUsername: String
    public let authorAvatarUrl: String
    public let photoUrl: String
    public let caption: String
    public let location: String?
    public let timestamp: Date
    public var likesCount: Int
    public var commentsCount: Int
    public var isLikedByMe: Bool
    public var previewComments: [PreviewComment]
}

public struct PreviewComment: Equatable, Codable, Sendable {
    public let id: String
    public let authorUsername: String
    public let text: String
}

// MARK: - Pagination primitives

/// Opaque token — client never inspects or constructs this.
/// Matches the `nextCursor: String?` field from GET /feed response.
public struct Cursor: Equatable, Codable, Sendable {
    public let value: String
    public init(_ value: String) { self.value = value }
}

/// One page returned by the API. Repository consumes this internally —
/// the ViewModel never sees a Page, only the accumulated store stream.
public struct Page<Item: Sendable>: Sendable {
    public let items: [Item]
    public let nextCursor: Cursor?
}

// MARK: - Like intent (outbox row)

/// Persisted in the LikeQueue (outbox). Survives app kill.
/// Worker picks these up and drains them to POST/DELETE /posts/{id}/like.
public struct LikeIntent: Codable, Sendable {
    public enum Action: String, Codable, Sendable { case like, unlike }
    public let id: String          // UUID for the intent row itself
    public let postId: String
    public let action: Action
    public let createdAt: Date
    public var retryCount: Int

    public init(postId: String, action: Action) {
        self.id = UUID().uuidString
        self.postId = postId
        self.action = action
        self.createdAt = Date()
        self.retryCount = 0
    }
}
