#if canImport(GRDB)
import Foundation
import GRDB

// MARK: - GRDB conformances
// The domain model stays framework-free (see Domain/Models.swift). The GRDB
// record conformances live HERE, in the persistence layer, via an extension —
// so Post can be saved/fetched without the model knowing GRDB exists.
//
// `previewComments` is a `[PreviewComment]`; GRDB's Codable record support
// stores non-scalar properties as JSON automatically, so it maps to a single
// JSON-text column.
extension Post: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "post"
}

// MARK: - GRDBPostStore (production persistence)
// A real SQLite-backed PostStore. Same protocol as InMemoryPostStore, so the
// repository above it cannot tell the difference. Reads observe the database via
// GRDB's ValueObservation, which — exactly like InMemoryPostStore.broadcast() —
// re-emits the full snapshot on every write, keeping the single source of truth
// honest.
//
// Thread-safety: a DatabaseWriter (pool/queue) is internally synchronised, so
// this is a final class marked @unchecked Sendable rather than an actor.
public final class GRDBPostStore: PostStore, @unchecked Sendable {

    // MARK: Configuration — this is where production and testing diverge

    public struct Configuration: Sendable {
        public enum Location: Sendable {
            case onDisk(path: String)   // production: durable, WAL, concurrent reads
            case inMemory               // tests: ephemeral, fresh per process
        }

        public enum Schema: String, Sendable {
            case production   // full schema + indexes for feed ordering & author lookups
            case testing      // minimal schema, no extra indexes — fast setup
        }

        public var location: Location
        public var schema: Schema

        /// On-disk store in the app's Documents directory with the production schema.
        public static func production() throws -> Configuration {
            let dir = try FileManager.default.url(
                for: .documentDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            )
            let path = dir.appendingPathComponent("photofeed.db").path
            return Configuration(location: .onDisk(path: path), schema: .production)
        }

        /// In-memory store with the lean testing schema. Use this to exercise the
        /// real GRDB code path in unit tests without touching disk.
        public static func testing() -> Configuration {
            Configuration(location: .inMemory, schema: .testing)
        }
    }

    private let dbWriter: any DatabaseWriter

    public init(configuration: Configuration) throws {
        var grdbConfig = GRDB.Configuration()
        // Surface SQL on the verbose (testing) path so you can trace what the
        // store actually executes.
        if Log.isVerbose {
            grdbConfig.prepareDatabase { db in
                db.trace { Log.db.debug("SQL: \($0.description, privacy: .public)") }
            }
        }

        switch configuration.location {
        case .onDisk(let path):
            dbWriter = try DatabasePool(path: path, configuration: grdbConfig)
        case .inMemory:
            dbWriter = try DatabaseQueue(configuration: grdbConfig)
        }

        try Self.migrator(for: configuration.schema).migrate(dbWriter)
        Log.db.notice("GRDBPostStore ready — schema=\(configuration.schema.rawValue, privacy: .public)")
    }

    // MARK: Schema / migrations — different per environment

    private static func migrator(for schema: Configuration.Schema) -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
        // During development, rebuild the DB when a migration definition changes.
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        // v1 — the base table, shared by both schemas.
        migrator.registerMigration("v1_create_post") { db in
            try db.create(table: "post") { t in
                t.primaryKey("id", .text)
                t.column("authorId",        .text).notNull()
                t.column("authorUsername",  .text).notNull()
                t.column("authorAvatarUrl", .text).notNull()
                t.column("photoUrl",        .text).notNull()
                t.column("caption",         .text).notNull()
                t.column("location",        .text)
                t.column("timestamp",       .datetime).notNull()
                t.column("likesCount",      .integer).notNull().defaults(to: 0)
                t.column("commentsCount",   .integer).notNull().defaults(to: 0)
                t.column("isLikedByMe",     .boolean).notNull().defaults(to: false)
                t.column("previewComments", .jsonText).notNull().defaults(to: "[]")
            }
        }

        // v2 — production-only indexes. Testing keeps the lean schema, so the two
        // environments genuinely differ at the SQL level, not just in config.
        if schema == .production {
            migrator.registerMigration("v2_production_indexes") { db in
                try db.create(index: "idx_post_timestamp", on: "post", columns: ["timestamp"])
                try db.create(index: "idx_post_author",    on: "post", columns: ["authorId"])
            }
        }

        return migrator
    }

    // MARK: PostStore

    public func upsert(_ posts: [Post]) async throws {
        try await interval("GRDBPostStore.upsert", Log.db, "count=\(posts.count)") {
            try await dbWriter.write { db in
                for post in posts { try post.save(db) }
            }
        }
        trace(Log.db, "upsert committed \(posts.count) rows")
    }

    public func updateLike(postId: String, isLiked: Bool, delta: Int) async throws {
        try await dbWriter.write { db in
            try db.execute(
                sql: "UPDATE post SET isLikedByMe = ?, likesCount = MAX(0, likesCount + ?) WHERE id = ?",
                arguments: [isLiked, delta, postId]
            )
        }
        trace(Log.db, "updateLike post=\(postId) liked=\(isLiked) delta=\(delta)")
    }

    public func replaceAll(_ posts: [Post]) async throws {
        try await interval("GRDBPostStore.replaceAll", Log.db, "count=\(posts.count)") {
            try await dbWriter.write { db in
                _ = try Post.deleteAll(db)
                for post in posts { try post.insert(db) }
            }
        }
    }

    public func observeAll() async -> AsyncThrowingStream<[Post], Error> {
        // ValueObservation re-emits the full ordered snapshot on every write —
        // the GRDB equivalent of InMemoryPostStore.broadcast().
        let observation = ValueObservation.tracking { db in
            try Post.order(Column("timestamp").desc).fetchAll(db)
        }
        let writer = dbWriter
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await rows in observation.values(in: writer) {
                        trace(Log.db, "ValueObservation emitted \(rows.count) rows")
                        continuation.yield(rows)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func count() async throws -> Int {
        try await dbWriter.read { db in try Post.fetchCount(db) }
    }
}
#endif
