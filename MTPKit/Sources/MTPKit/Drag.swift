import Foundation

/// Counts the promise writes of one drag. AppKit issues every `writePromiseTo` of a drop back to back before any
/// completion (RESEARCH S1), so waiting for all of them turns one drag into one job (D-01). The same type counts the
/// promise-reader callbacks of a promise drop in (05-08).
public struct PromiseBatch: Sendable, Equatable {
    public enum Step: Sendable, Equatable {
        /// Keep what arrived; more is coming.
        case wait
        /// Start one job with everything that arrived so far.
        case start
        /// The batch already started: this arrival gets its own job, so nothing is dropped.
        case startAlone
    }

    public let expected: Int
    /// Still counted after the start (05-08 relies on it).
    public private(set) var arrived = 0
    public private(set) var started = false

    public init(expected: Int) { self.expected = expected }

    public mutating func arrive() -> Step {
        arrived += 1
        if started { return .startAlone }
        guard arrived >= expected else { return .wait }
        started = true
        return .start
    }

    /// The fallback after the drag ended: a receiver that asked for fewer items can't hold the job back, and a drag
    /// with nothing arrived (cancelled) starts nothing.
    public mutating func flush() -> Step {
        guard !started, arrived > 0 else { return .wait }
        started = true
        return .start
    }

    /// Groups `items` by the folder each one's URL names, groups in first-seen order and items in their own order.
    /// Every write lands in the folder its own URL names (D-04, D-05); Finder names one folder per drop, so a Finder
    /// drag stays one group and one job (D-01).
    public static func byFolder<Item>(_ items: [Item], url: (Item) -> URL) -> [[Item]] {
        var order: [URL] = []
        var groups: [URL: [Item]] = [:]
        for item in items {
            let folder = url(item).deletingLastPathComponent().standardizedFileURL
            if groups[folder] == nil { order.append(folder) }
            groups[folder, default: []].append(item)
        }
        return order.map { groups[$0]! }
    }
}

/// A value per job, each handed back exactly once when its job ends: the end detection behind D-05, kept pure so it is
/// tested. A promise completion is never left waiting nor called twice.
public struct JobLedger<Job: Hashable, Value> {
    private var values: [Job: Value] = [:]

    public init() {}

    public mutating func record(_ value: Value, for job: Job) { values[job] = value }

    /// Removes and returns the value of every recorded job not in `live`.
    public mutating func takeEnded(live: Set<Job>) -> [Value] {
        let ended = values.keys.filter { !live.contains($0) }
        return ended.compactMap { values.removeValue(forKey: $0) }
    }
}

extension JobLedger: Sendable where Job: Sendable, Value: Sendable {}

/// What a drag out's promises are told when its job ends (D-05), kept pure so it is tested.
public enum EndReport: Equatable, Sendable {
    /// Left from copying: every item landed.
    case landed
    /// A stop or a free-space refusal: nothing to report.
    case silent
    /// A failed row: the top-level items in `tops` didn't land, the rest did; nil when a failure names no item
    /// (planning), so none did.
    case failed(tops: Set<Int>?)

    /// What the promise of top-level item `top` is told: nothing when it landed, the silent `userCancelled` on a stop
    /// or a refusal, an error when its copy failed (the receiver may show its own alert then).
    public func error(top: Int) -> (any Error)? {
        switch self {
        case .landed: nil
        case .silent: CocoaError(.userCancelled)
        case .failed(let tops): tops?.contains(top) == false ? nil : CocoaError(.fileWriteUnknown)
        }
    }
}

extension TransferJobs {
    /// The report for job `id`, which `old` held and which just left the live jobs: still listed is its failed row;
    /// gone, it finished only if it left from copying (a stop leaves from canceling or before it ran, a space refusal
    /// from preparing).
    public func endReport(for id: TransferJob.ID, was old: TransferJobs) -> EndReport {
        if let job = all.first(where: { $0.id == id }) {
            let keys = job.failures.map(\.key)
            return .failed(tops: keys.contains(nil) ? nil : Set(keys.compactMap { $0?.top }))
        }
        return old.all.first { $0.id == id }?.state == .copying ? .landed : .silent
    }
}

/// The only place that decides when a promise drop's staging folder may be deleted (D-10, T-05-32): a folder stays
/// while its drop holds it (a promised file can still arrive) or any recorded job still uses it (running, or a failed
/// row kept for Retry). The app deletes exactly what this returns, and nothing else.
public struct StagingLedger<Job: Hashable & Sendable>: Sendable {
    private var folders: [Job: URL] = [:]
    private var held: Set<URL> = []

    public init() {}

    /// The drop is open: nothing in `folder` may go until `release(_:)`.
    public mutating func hold(_ folder: URL) { held.insert(folder) }

    public mutating func record(_ folder: URL, for job: Job) { folders[job] = folder }

    public func folder(for job: Job) -> URL? { folders[job] }

    /// The drop is finished. Returns `folder` when no recorded job uses it (delete it now), else nil (it goes with its
    /// last job, through `jobsLeft(live:)`).
    public mutating func release(_ folder: URL) -> URL? {
        held.remove(folder)
        return folders.values.contains(folder) ? nil : folder
    }

    /// Forgets every recorded job not in `live` and returns, once each, the folders those jobs used that no remaining
    /// job uses and no drop holds.
    public mutating func jobsLeft(live: Set<Job>) -> [URL] {
        let ended = folders.keys.filter { !live.contains($0) }
        let freed = Set(ended.compactMap { folders.removeValue(forKey: $0) })
        return freed.filter { !held.contains($0) && !folders.values.contains($0) }.sorted { $0.path < $1.path }
    }
}
