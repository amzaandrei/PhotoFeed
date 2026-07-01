# PhotoFeed

An Instagram-style photo feed built in SwiftUI, structured around a strict,
one-way dependency rule and a single source of truth. The feed paginates with
infinite scroll, likes are optimistic and survive an app kill via a persistent
outbox, and impressions are batched and flushed.

Everything below the UI is framework-light and protocol-driven, so the whole app
runs today on in-memory mocks and switches to a real backend / database by
changing **one line** in the composition root.

---

## Layers

```
Domain         Pure value types (Post, PreviewComment, Cursor, Page, LikeIntent).
               No SwiftUI, no persistence imports.

Networking     FeedAPIClient / LikeAPIClient protocols (+ Mock implementations).

Persistence    PostStore  — the single source of truth. Emits the full snapshot
               on every write. LikeQueue — a durable outbox of like/unlike intents.

Repository     FeedRepository / LikeRepository. Actors that compose API + Store,
               own pagination state (the cursor), and expose intents.

Services       LikeQueueWorker (drains the outbox to the API with retries),
               ImpressionTracker (batches "seen" post IDs and flushes them).

Presentation   FeedViewModel — @MainActor ObservableObject. Holds @Published state
               the View binds to. Depends only on repository protocols.

UI             FeedView + cells. Renders viewModel.posts, forwards user intents.

App            PhotoFeedApp — the composition root. The ONLY place that names
               concrete types and wires everything together.
```

---

## Data flow

The golden rule: **the UI observes the store, never the network.** A write is an
*intent* that returns `Void`; new data reaches the screen only by the store
re-emitting its snapshot. This is what keeps state consistent.

```
        ┌──────────┐   intent (toggleLike / loadMore / refresh)
        │ FeedView │ ───────────────────────────────────────────┐
        └────┬─────┘                                             │
             │ binds to @Published posts                         ▼
             │                                           ┌───────────────┐
             │                                           │ FeedViewModel │
             │                                           └───────┬───────┘
             │                                                   │ calls intent
             │                                                   ▼
             │                                          ┌──────────────────┐
             │                                          │  FeedRepository  │
             │                                          │  (actor, owns    │
             │                                          │   the cursor)    │
             │                                          └───┬───────────┬──┘
             │                                              │ fetch     │ write
             │                                              ▼           ▼
             │                                     ┌──────────────┐ ┌──────────┐
             │                                     │ FeedAPIClient│ │ PostStore│
             │                                     └──────────────┘ └────┬─────┘
             │                                                            │
             │        observePosts() ── AsyncThrowingStream<[Post]> ──────┘
             └────────────────────── snapshot re-emitted on EVERY write ──┘
```

Read path (one-way):  `PostStore → Repository.observePosts() → ViewModel.posts → FeedView`

Write paths (intents, return `Void`):

- **Pagination** — `FeedView` reaches 3 cells from the end → `loadMore()` →
  `repo.loadNextPage()` fetches with the repo-held cursor → `store.upsert(page)`
  → store re-emits → list grows. The cursor is **private to the repository**; the
  ViewModel can neither see nor set it.
- **Likes (optimistic + durable)** — `toggleLike` → `LikeRepository` writes the
  new like state to the store immediately (UI updates at once) **and** appends a
  `LikeIntent` to the `LikeQueue` outbox. `LikeQueueWorker` drains the outbox to
  the API in the background with retries, so a like survives an app kill.
- **Impressions** — `didSeePost` feeds IDs to `ImpressionTracker`, which batches
  and flushes them (e.g. `POST /impressions`).

---

## Dependency flow

Dependencies point **inward**, toward the framework-free Domain. Nothing in a
lower layer imports a higher one; every collaborator is referenced through a
protocol.

```
   App (composition root)
        │   constructs concrete types, injects downward
        ▼
   UI  ──►  Presentation  ──►  Repository ──►  Networking
                                   │      └───►  Persistence
                                   └──────────►  Domain  ◄── (everyone depends on Domain)
                                                  ▲
   Services ─────────────────────────────────────┘
```

- The **ViewModel** depends on `FeedRepository` / `LikeRepository` *protocols*,
  not concrete actors.
- The **repositories** depend on `FeedAPIClient` / `PostStore` / `LikeQueue`
  *protocols*, not concrete mocks or databases.
- Only **`PhotoFeedApp`** knows the concrete graph. That is the dependency
  inversion payoff: swap an implementation there and nothing else changes.

```swift
// PhotoFeedApp.swift — the one place wiring lives
private let postStore: PostStore     = InMemoryPostStore()   // → GRDBPostStore(path:)
private let feedApi:  FeedAPIClient   = MockFeedAPIClient()   // → LiveFeedAPIClient(baseURL:)
```

Going to production is two edits in that file — in-memory store → GRDB,
mock API → live API. No other file changes.

---

## Project layout

```
PhotoFeed/
├── Domain/Models.swift
├── Networking/FeedAPIClient.swift
├── Persistence/{PostStore,LikeQueue}.swift
├── Repository/{FeedRepository,LikeRepository}.swift
├── Services/{LikeQueueWorker,ImpressionTracker}.swift
├── Presentation/FeedViewModel.swift
├── UI/FeedView.swift
├── PhotoFeedApp.swift        # composition root
└── project.yml               # XcodeGen spec
```

## Build & run

The Xcode project is generated from `project.yml` with
[XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen     # if needed
xcodegen generate
open PhotoFeed.xcodeproj
```

Then build/run the `PhotoFeed` scheme on an iOS 17+ simulator. Requires Xcode 16+.
After adding or moving files, re-run `xcodegen generate`.

## Design notes

- **Single source of truth** — the store is the only thing the UI reads; writes
  fan out through it, so two screens can never disagree.
- **Concurrency by construction** — repositories and the store are `actor`s, so
  mutable state (the cursor, the in-memory map) is safe without locks.
- **Offline-tolerant likes** — the outbox pattern (`LikeQueue` + worker) means a
  tap is recorded durably first and synced later.
- **Testability** — every dependency is a protocol, so the ViewModel and
  repositories can be exercised against fakes with no UIKit/SwiftUI in the loop.
