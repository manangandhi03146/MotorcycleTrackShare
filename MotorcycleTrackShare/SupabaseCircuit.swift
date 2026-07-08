import Foundation

/// Circuit breaker in front of Supabase-backed reads so a slow or
/// failing dependency doesn't drag every tab down at once. Also
/// enforces a per-request timeout (URLSession's default 60s is way
/// too long for a user staring at a spinner) and caps concurrency
/// per category so a single flapping endpoint can't saturate all six
/// URLSession per-host connections.
///
/// Not applied to writes (create group, share ride, etc.) — those are
/// user-initiated, one-off, and already surface their own errors. This
/// is purely for the *reads* the tabs fire on entry, where failure
/// cascades into visible spinner hell.
actor SupabaseCircuit {
    static let shared = SupabaseCircuit()

    enum State: Sendable, Equatable {
        case closed
        case open(until: Date)
        case halfOpen
    }

    /// Categories are the "bulkhead" boundaries: a broken feed query
    /// shouldn't open the circuit for challenges too, and vice versa.
    /// Callers pick a stable string that maps to a logical endpoint.
    enum Category: String, Sendable {
        case feed, groups, challenges, mutuals, profile, search
    }

    struct CircuitOpenError: LocalizedError {
        let category: Category
        let retryAfter: Date
        var errorDescription: String? {
            "\(category.rawValue.capitalized) is temporarily unavailable. Showing the last known data."
        }
    }

    struct CircuitTimeoutError: LocalizedError {
        let category: Category
        let seconds: TimeInterval
        var errorDescription: String? {
            "\(category.rawValue.capitalized) took too long (>\(Int(seconds))s). Try again shortly."
        }
    }

    // MARK: - Tunables

    /// Trip open after this many consecutive failures. A single flaky
    /// request shouldn't kill the whole tab.
    private let failureThreshold = 3
    /// Per-request wall-clock ceiling. Anything slower is treated as a
    /// failure and counted against the threshold.
    private let requestTimeout: TimeInterval = 10
    /// How long the circuit stays open before a half-open probe.
    private let cooldown: TimeInterval = 30
    /// Max concurrent in-flight requests per category. Keeps a bursty
    /// category from monopolizing the shared URLSession pool.
    private let concurrencyCap = 3

    // MARK: - Per-category state

    private struct Bucket {
        var state: State = .closed
        var consecutiveFailures = 0
        var inflight = 0
    }

    private var buckets: [Category: Bucket] = [:]

    // MARK: - Public API

    /// Runs `operation` behind the circuit for `category`. Semantics:
    /// - Closed: run normally; failures increment the counter, N in a
    ///   row flip the circuit open.
    /// - Open: fast-fail with `CircuitOpenError` (no network hit) until
    ///   `cooldown` elapses, then next call becomes a half-open probe.
    /// - Half-open: exactly one probe allowed; success closes the
    ///   circuit, failure re-opens it with a fresh cooldown.
    func run<T: Sendable>(
        _ category: Category,
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await preflight(category)
        do {
            let value = try await withTimeout(requestTimeout, category: category) {
                try await operation()
            }
            recordSuccess(category)
            return value
        } catch let error as CancellationError {
            // Task-level cancellation shouldn't count against the breaker.
            releaseSlot(category)
            throw error
        } catch {
            recordFailure(category)
            throw error
        }
    }

    /// Snapshot the current state — used by the UI to decide whether to
    /// show a degraded banner instead of spinning.
    func state(for category: Category) -> State {
        buckets[category]?.state ?? .closed
    }

    // MARK: - State transitions

    private func preflight(_ category: Category) async throws {
        var bucket = buckets[category] ?? Bucket()

        switch bucket.state {
        case .open(let until):
            if Date() >= until {
                bucket.state = .halfOpen
            } else {
                buckets[category] = bucket
                throw CircuitOpenError(category: category, retryAfter: until)
            }
        case .halfOpen:
            // Only one probe at a time in half-open; other callers
            // fast-fail rather than pile on a possibly-still-dead
            // dependency.
            if bucket.inflight > 0 {
                let until = Date().addingTimeInterval(cooldown)
                throw CircuitOpenError(category: category, retryAfter: until)
            }
        case .closed:
            break
        }

        // Concurrency cap: refuse rather than queue so callers can
        // return to their cached UI instead of stacking up spinners.
        if bucket.state == .closed, bucket.inflight >= concurrencyCap {
            throw CircuitOpenError(
                category: category,
                retryAfter: Date().addingTimeInterval(1)
            )
        }

        bucket.inflight += 1
        buckets[category] = bucket
    }

    private func recordSuccess(_ category: Category) {
        var bucket = buckets[category] ?? Bucket()
        bucket.consecutiveFailures = 0
        bucket.state = .closed
        bucket.inflight = max(0, bucket.inflight - 1)
        buckets[category] = bucket
    }

    private func recordFailure(_ category: Category) {
        var bucket = buckets[category] ?? Bucket()
        bucket.consecutiveFailures += 1
        bucket.inflight = max(0, bucket.inflight - 1)

        if bucket.consecutiveFailures >= failureThreshold {
            bucket.state = .open(until: Date().addingTimeInterval(cooldown))
        } else if case .halfOpen = bucket.state {
            // Half-open probe failed → straight back to open.
            bucket.state = .open(until: Date().addingTimeInterval(cooldown))
        }
        buckets[category] = bucket
    }

    private func releaseSlot(_ category: Category) {
        var bucket = buckets[category] ?? Bucket()
        bucket.inflight = max(0, bucket.inflight - 1)
        buckets[category] = bucket
    }
}

// MARK: - Timeout race

/// Races `operation` against a sleep. First finisher wins; the loser
/// is cancelled. Works with any async throwing operation without
/// requiring the target library to expose a native deadline knob
/// (Supabase's Swift SDK doesn't).
private func withTimeout<T: Sendable>(
    _ seconds: TimeInterval,
    category: SupabaseCircuit.Category,
    _ operation: @Sendable @escaping () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw SupabaseCircuit.CircuitTimeoutError(category: category, seconds: seconds)
        }
        // First one back wins; cancel the other before returning.
        let winner = try await group.next()!
        group.cancelAll()
        return winner
    }
}
