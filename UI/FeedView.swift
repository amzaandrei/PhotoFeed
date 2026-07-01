import SwiftUI

// MARK: - FeedView
// Dumb: renders viewModel.posts, forwards intents.
// The infinite scroll trigger fires when the last post's cell appears —
// not on the very last row, but 3 rows before it, so the next page is
// already in flight before the user reaches the bottom.

public struct FeedView: View {
    @StateObject private var viewModel: FeedViewModel

    public init(viewModel: FeedViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(viewModel.posts.enumerated()), id: \.element.id) { index, post in
                        PostCell(post: post) {
                            viewModel.toggleLike(post: post)
                        }
                        .onAppear {
                            viewModel.didSeePost(post)
                            // Prefetch: trigger load when 3 posts from the end
                            if index == viewModel.posts.count - 3 {
                                Task { await viewModel.loadMore() }
                            }
                        }
                        Divider()
                    }

                    if viewModel.isLoading {
                        ProgressView()
                            .padding(.vertical, 24)
                    }
                }
            }
            .refreshable { await viewModel.refresh() }
            .navigationTitle("Feed")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task { viewModel.onAppear() }
        .alert("Error", isPresented: .constant(viewModel.errorMessage != nil)) {
            Button("OK") { }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }
}

// MARK: - PostCell

struct PostCell: View {
    let post:       Post
    let onLikeTap:  () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 10) {
                AvatarView(url: post.authorAvatarUrl, size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(post.authorUsername)
                        .font(.system(size: 14, weight: .semibold))
                    if let loc = post.location {
                        Text(loc)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "ellipsis")
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            // Photo — fills full width, square crop
            // In production: use KingFisher's KFImage(URL(string: post.photoUrl))
            AsyncImage(url: URL(string: post.photoUrl)) { phase in
                switch phase {
                case .success(let img):
                    img.resizable()
                       .aspectRatio(1, contentMode: .fill)
                       .clipped()
                case .failure:
                    Rectangle()
                        .fill(Color.secondary.opacity(0.15))
                        .aspectRatio(1, contentMode: .fit)
                        .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                default:
                    Rectangle()
                        .fill(Color.secondary.opacity(0.08))
                        .aspectRatio(1, contentMode: .fit)
                        .overlay(ProgressView())
                }
            }
            .frame(maxWidth: .infinity)

            // Action bar
            HStack(spacing: 16) {
                LikeButton(isLiked: post.isLikedByMe, onTap: onLikeTap)
                Button { } label: { Image(systemName: "bubble.right") }
                Button { } label: { Image(systemName: "paperplane") }
                Spacer()
                Image(systemName: "bookmark")
            }
            .font(.system(size: 22))
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            // Like count
            Text("\(post.likesCount.formatted()) likes")
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 12)

            // Caption
            HStack(alignment: .top, spacing: 4) {
                Text(post.authorUsername)
                    .font(.system(size: 14, weight: .semibold))
                Text(post.caption)
                    .font(.system(size: 14))
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)

            // Preview comments (max 2)
            ForEach(post.previewComments.prefix(2), id: \.id) { comment in
                HStack(alignment: .top, spacing: 4) {
                    Text(comment.authorUsername)
                        .font(.system(size: 13, weight: .semibold))
                    Text(comment.text)
                        .font(.system(size: 13))
                }
                .padding(.horizontal, 12)
                .padding(.top, 2)
            }

            if post.commentsCount > 2 {
                Text("View all \(post.commentsCount) comments")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 2)
            }

            // Timestamp
            Text(post.timestamp, style: .relative)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .padding(.bottom, 12)
        }
    }
}

// MARK: - LikeButton
// Animated heart — fills and bounces on tap.
// The state is driven by post.isLikedByMe from the SSOT store,
// not local @State, so it's always consistent with the truth.

struct LikeButton: View {
    let isLiked: Bool
    let onTap:   () -> Void
    @State private var bouncing = false

    var body: some View {
        Button {
            bouncing = true
            onTap()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { bouncing = false }
        } label: {
            Image(systemName: isLiked ? "heart.fill" : "heart")
                .foregroundStyle(isLiked ? .red : .primary)
                .scaleEffect(bouncing ? 1.3 : 1.0)
                .animation(.spring(response: 0.25, dampingFraction: 0.5), value: bouncing)
        }
    }
}

// MARK: - AvatarView

struct AvatarView: View {
    let url:  String
    let size: CGFloat

    var body: some View {
        AsyncImage(url: URL(string: url)) { phase in
            if let img = phase.image {
                img.resizable().scaledToFill()
            } else {
                Circle().fill(Color.secondary.opacity(0.2))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

// MARK: - Preview

#Preview {
    let store    = InMemoryPostStore()
    let queue    = InMemoryLikeQueue()
    let api      = MockFeedAPIClient(delay: .milliseconds(200))
    let likeApi  = MockLikeAPIClient()
    let feedRepo = DefaultFeedRepository(api: api, store: store)
    let likeRepo = DefaultLikeRepository(store: store, queue: queue)
    let worker   = LikeQueueWorker(queue: queue, api: likeApi, store: store)
    let tracker  = ImpressionTracker { ids in print("Seen: \(ids)") }
    let vm       = FeedViewModel(feedRepo: feedRepo, likeRepo: likeRepo, impressions: tracker)

    Task { await worker.start() }

    return FeedView(viewModel: vm)
}
