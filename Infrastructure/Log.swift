import Foundation
import os

// MARK: - Log
// Centralised logging + signposting for tracing what Swift Concurrency actually
// does at runtime: which Task runs where, when actors are entered, and how async
// operations overlap.
//
// Two complementary tools, both from Apple's unified logging system:
//
//   • Logger (os_log) — structured text you read live in Console.app, filtered by
//     subsystem + category. `.debug` is for high-volume per-hop concurrency
//     traces (auto-suppressed unless you're actively looking), `.info`/`.notice`
//     for lifecycle, `.error` for failures.
//
//   • OSSignposter — interval/event markers you scrub on the Instruments
//     timeline ("os_signpost" / Points of Interest). Wrap an async operation in
//     `interval(...)` to SEE its start, end, and overlap across actors — this is
//     the thing that makes concurrency legible.
//
// View live:   Console.app → filter subsystem:com.andreiamza.PhotoFeed
// Or in shell: log stream --predicate 'subsystem == "com.andreiamza.PhotoFeed"' --level debug
// Timeline:    Instruments → os_signpost / Points of Interest instrument

public enum Log {
    public static let subsystem = "com.andreiamza.PhotoFeed"

    public static let app        = Logger(subsystem: subsystem, category: "app")
    public static let store      = Logger(subsystem: subsystem, category: "store")
    public static let db         = Logger(subsystem: subsystem, category: "db")
    public static let repository = Logger(subsystem: subsystem, category: "repository")
    public static let like       = Logger(subsystem: subsystem, category: "like")
    public static let worker     = Logger(subsystem: subsystem, category: "worker")
    public static let impression = Logger(subsystem: subsystem, category: "impression")
    public static let viewModel  = Logger(subsystem: subsystem, category: "viewModel")

    /// Drives signpost intervals shown in Instruments' "Points of Interest".
    public static let signposter = OSSignposter(subsystem: subsystem, category: .pointsOfInterest)

    /// When false (production), the verbose per-hop concurrency traces are skipped
    /// before any string is built — production pays nothing. Set from
    /// `AppEnvironment` at boot.
    public static var isVerbose = false
}

// MARK: - Concurrency context

/// A compact, stable-for-its-lifetime identifier for the currently executing
/// Task. Print it on every trace and you can follow ONE async operation as it
/// suspends, resumes, and hops between actors/threads.
@inline(__always)
public func taskTag() -> String {
    withUnsafeCurrentTask { task in
        guard let task else { return "no-task" }
        return String(format: "t%04X", UInt(bitPattern: task.hashValue) & 0xFFFF)
    }
}

/// Where is this code executing right now? Confirms actor hops and the
/// @MainActor boundary at a glance (`main` vs `bg`).
@inline(__always)
public func execContext() -> String {
    Thread.isMainThread ? "main" : "bg"
}

// MARK: - Trace (verbose, gated)

/// Verbose concurrency trace. No-op (and zero interpolation cost) unless
/// `Log.isVerbose` is on, so it's safe to sprinkle liberally.
///
/// Output: `[t1A2F|bg] functionName: message`
@inline(__always)
public func trace(_ logger: Logger,
                  _ message: @autoclosure () -> String,
                  function: String = #function) {
    guard Log.isVerbose else { return }
    let text = message()          // evaluate before interpolation (avoids escaping-autoclosure capture)
    let tag  = taskTag()
    let ctx  = execContext()
    logger.debug("[\(tag, privacy: .public)|\(ctx, privacy: .public)] \(function, privacy: .public): \(text, privacy: .public)")
}

// MARK: - Signpost interval (works across await)

/// Wrap an async operation in a signpost interval. It shows up as a labelled span
/// on the Instruments timeline — begin and end can land on different threads
/// across `await`, which is exactly what makes suspension visible. When verbose,
/// also logs begin/end stamped with the Task tag.
@discardableResult
public func interval<T>(_ name: StaticString,
                        _ logger: Logger = Log.app,
                        _ detail: @autoclosure () -> String = "",
                        operation: () async throws -> T) async rethrows -> T {
    let signposter = Log.signposter
    let state = signposter.beginInterval(name, id: signposter.makeSignpostID())
    let tag = taskTag()
    if Log.isVerbose {
        let nameStr = "\(name)"
        let d = detail()
        logger.debug("[\(tag, privacy: .public)] ▶ \(nameStr, privacy: .public) \(d, privacy: .public)")
    }
    defer {
        signposter.endInterval(name, state)
        if Log.isVerbose {
            let nameStr = "\(name)"
            logger.debug("[\(tag, privacy: .public)] ◼ \(nameStr, privacy: .public)")
        }
    }
    return try await operation()
}

/// Emit a one-shot signpost event (a moment, not a span) plus an optional
/// verbose log line.
@inline(__always)
public func event(_ name: StaticString,
                  _ logger: Logger = Log.app,
                  _ detail: @autoclosure () -> String = "") {
    Log.signposter.emitEvent(name)
    if Log.isVerbose {
        let nameStr = "\(name)"
        let d = detail()
        logger.debug("• \(nameStr, privacy: .public) \(d, privacy: .public)")
    }
}
