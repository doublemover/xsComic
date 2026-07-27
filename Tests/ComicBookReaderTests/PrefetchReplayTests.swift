import Foundation
import XCTest
@testable import ComicBookReader

/// A deterministic laboratory for prefetch policy.
///
/// Production preserves visible pages, keeps two pages behind, and speculates
/// about eight ahead. The candidate adds only a tiny reverse-streak signal.
/// Synthetic reading traces compare misses and stalls under cache pressure
/// without putting telemetry, history storage, or a learned model in the app.
final class PrefetchReplayTests: XCTestCase {
    /// Candidate and baseline may reorder priorities, but neither may enlarge
    /// the bounded window or omit a visible page.
    func testPoliciesKeepTheSameBoundedWindow() {
        for pageCount in [1, 2, 3, 11, 64] {
            for step in [1, 2] {
                for index in stride(from: 0, to: pageCount, by: step) {
                    for streak: UInt8 in 0...2 {
                        let baseline = plan(
                            pageCount: pageCount,
                            index: index,
                            step: step,
                            reverseStreak: streak,
                            adaptive: false
                        )
                        let candidate = plan(
                            pageCount: pageCount,
                            index: index,
                            step: step,
                            reverseStreak: streak,
                            adaptive: true
                        )
                        let visibleEnd = min(index + step, pageCount)
                        let expectedVisible = Set(index..<visibleEnd)
                        let expectedPrefetch = Set(
                            max(0, index - ReaderModel.backwardBufferPageCount)..<index
                        ).union(
                            visibleEnd..<min(
                                visibleEnd + ReaderModel.forwardPrefetchPageCount,
                                pageCount
                            )
                        )

                        XCTAssertEqual(Set(baseline.retention), Set(candidate.retention))
                        XCTAssertEqual(Set(baseline.prefetch), Set(candidate.prefetch))
                        XCTAssertEqual(Set(baseline.visible), expectedVisible)
                        XCTAssertEqual(Set(baseline.prefetch), expectedPrefetch)
                        XCTAssertEqual(Set(baseline.retention), expectedVisible.union(expectedPrefetch))
                        XCTAssertEqual(baseline.retention.count, Set(baseline.retention).count)
                        XCTAssertEqual(baseline.prefetch.count, Set(baseline.prefetch).count)
                        XCTAssertLessThanOrEqual(
                            baseline.retention.count,
                            PageImageStore.entryLimit
                        )
                        XCTAssertLessThanOrEqual(
                            baseline.prefetch.count,
                            ReaderModel.forwardPrefetchPageCount
                                + ReaderModel.backwardBufferPageCount
                        )
                        XCTAssertTrue(baseline.retention.allSatisfy { (0..<pageCount).contains($0) })
                        XCTAssertTrue(baseline.prefetch.allSatisfy { (0..<pageCount).contains($0) })

                        if streak < 2 {
                            XCTAssertEqual(baseline, candidate)
                        }
                    }
                }
            }
        }
    }

    /// Sweep capacity and refill budget: a predictor that wins only with an
    /// unrealistically fast decoder is not useful on real comic pages.
    func testPrefetchReplayBenchmark() throws {
        guard ProcessInfo.processInfo.environment["CBR_BENCHMARK"] == "1" else {
            throw XCTSkip("Set CBR_BENCHMARK=1 to run performance benchmarks.")
        }

        // Twelve is production's entry cap; smaller values model byte eviction
        // when individual decoded pages consume the 64 MiB budget.
        let capacities = [4, 6, 8, 12]
        let refillBudgets = [0, 1, 2, 10]
        var totalBaseline = Metrics()
        var totalCandidate = Metrics()
        var totalWins = 0
        var totalLosses = 0

        for (name, actions) in traces() {
            for step in [1, 2] {
                var baselineAggregate = Metrics()
                var candidateAggregate = Metrics()
                var wins = 0
                var losses = 0

                for capacity in capacities {
                    for refillBudget in refillBudgets {
                        let baseline = replay(
                            actions,
                            step: step,
                            capacity: capacity,
                            refillBudget: refillBudget,
                            adaptive: false
                        )
                        let candidate = replay(
                            actions,
                            step: step,
                            capacity: capacity,
                            refillBudget: refillBudget,
                            adaptive: true
                        )
                        baselineAggregate += baseline
                        candidateAggregate += candidate
                        if candidate.demandMisses < baseline.demandMisses {
                            wins += 1
                        } else if candidate.demandMisses > baseline.demandMisses {
                            losses += 1
                        }
                    }
                }

                totalBaseline += baselineAggregate
                totalCandidate += candidateAggregate
                totalWins += wins
                totalLosses += losses
                print(
                    "CBR_METRIC prefetch_replay trace=\(name) step=\(step)"
                        + " cases=\(capacities.count * refillBudgets.count)"
                        + " static_misses=\(baselineAggregate.demandMisses)"
                        + " adaptive_misses=\(candidateAggregate.demandMisses)"
                        + " static_stalls=\(baselineAggregate.stalledTurns)"
                        + " adaptive_stalls=\(candidateAggregate.stalledTurns)"
                        + " wins=\(wins) losses=\(losses)"
                )
            }
        }

        print(
            "CBR_METRIC prefetch_replay_total"
                + " static_misses=\(totalBaseline.demandMisses)"
                + " adaptive_misses=\(totalCandidate.demandMisses)"
                + " static_stalls=\(totalBaseline.stalledTurns)"
                + " adaptive_stalls=\(totalCandidate.stalledTurns)"
                + " static_prefetch_decodes=\(totalBaseline.prefetchDecodes)"
                + " adaptive_prefetch_decodes=\(totalCandidate.prefetchDecodes)"
                + " static_rejected=\(totalBaseline.rejectedPrefetches)"
                + " adaptive_rejected=\(totalCandidate.rejectedPrefetches)"
                + " wins=\(totalWins) losses=\(totalLosses)"
        )
    }

    /// Demand misses approximate blank-page risk; stalled turns count at most
    /// once per gesture; speculative decodes are the CPU/I/O price paid.
    private func replay(
        _ actions: [Int],
        step: Int,
        capacity: Int,
        refillBudget: Int,
        adaptive: Bool
    ) -> Metrics {
        let pageCount = 512
        var current = 0
        // This saturating byte is the whole candidate "model": enough to tell a
        // one-page correction from a sustained reread, with fixed storage.
        var reverseStreak: UInt8 = 0
        var cache = ReplayCache(capacity: capacity)
        var metrics = Metrics()

        var currentPlan = plan(
            pageCount: pageCount,
            index: current,
            step: step,
            reverseStreak: reverseStreak,
            adaptive: adaptive
        )
        cache.setRetention(currentPlan.retention)
        for page in currentPlan.visible {
            _ = cache.insert(page)
        }
        prefetch(currentPlan.prefetch, budget: refillBudget, cache: &cache, metrics: &metrics)

        for action in actions {
            if action > 0 {
                guard current + step < pageCount else { continue }
                current += step
                reverseStreak = 0
            } else {
                guard current > 0 else { continue }
                current = max(0, current - step)
                if reverseStreak < 2 { reverseStreak += 1 }
            }

            currentPlan = plan(
                pageCount: pageCount,
                index: current,
                step: step,
                reverseStreak: reverseStreak,
                adaptive: adaptive
            )
            cache.setRetention(currentPlan.retention)

            var missedThisTurn = false
            for page in currentPlan.visible where !cache.access(page) {
                metrics.demandMisses += 1
                missedThisTurn = true
                _ = cache.insert(page)
            }
            if missedThisTurn {
                metrics.stalledTurns += 1
            }

            prefetch(currentPlan.prefetch, budget: refillBudget, cache: &cache, metrics: &metrics)
        }

        return metrics
    }

    /// Spend a bounded background budget in priority order. A rejected insertion
    /// identifies speculation less valuable than the cache's retained pages.
    private func prefetch(
        _ pages: [Int],
        budget: Int,
        cache: inout ReplayCache,
        metrics: inout Metrics
    ) {
        var remaining = budget
        for page in pages {
            if cache.access(page) { continue }
            guard remaining > 0 else { return }
            remaining -= 1
            metrics.prefetchDecodes += 1
            if !cache.insert(page) {
                metrics.rejectedPrefetches += 1
            }
        }
    }

    /// Construct the same three-part contract as production: visible now,
    /// retention order, and speculative decode order.
    private func plan(
        pageCount: Int,
        index: Int,
        step: Int,
        reverseStreak: UInt8,
        adaptive: Bool
    ) -> Plan {
        let visibleEnd = min(index + step, pageCount)
        let nextEnd = min(
            visibleEnd + ReaderModel.forwardPrefetchPageCount,
            pageCount
        )
        let previousStart = max(
            0,
            index - ReaderModel.backwardBufferPageCount
        )
        let visible = Array(index..<visibleEnd)
        let upcoming = Array(visibleEnd..<nextEnd)
        let previous = Array(previousStart..<index).reversed()

        if adaptive, reverseStreak >= 2 {
            return Plan(
                visible: visible,
                retention: visible + previous + upcoming,
                prefetch: previous + upcoming
            )
        }
        return Plan(
            visible: visible,
            retention: visible + upcoming.prefix(2) + previous + upcoming.dropFirst(2),
            prefetch: upcoming + previous
        )
    }

    /// Each trace names recognizable behavior, so a changed metric can be
    /// explained from the raw sequence rather than blamed on random input.
    private func traces() -> [(String, [Int])] {
        [
            ("forward", Array(repeating: 1, count: 160)),
            ("correction", repeated([1, 1, 1, 1, 1, 1, 1, 1, -1, 1], count: 10)),
            (
                "reread",
                repeated(
                    Array(repeating: 1, count: 12)
                        + Array(repeating: -1, count: 3)
                        + Array(repeating: 1, count: 12),
                    count: 6
                )
            ),
            ("reverse", Array(repeating: 1, count: 96) + Array(repeating: -1, count: 48)),
            ("pingpong", Array(repeating: 1, count: 32) + repeated([-1, 1], count: 48)),
        ]
    }

    private func repeated(_ pattern: [Int], count: Int) -> [Int] {
        (0..<count).flatMap { _ in pattern }
    }
}

private struct Plan: Equatable {
    // Arrays encode priority. Sets would make admission order nondeterministic
    // and accidentally erase the policy being measured.
    let visible: [Int]
    let retention: [Int]
    let prefetch: [Int]
}

private struct Metrics {
    // Additive counters keep individual cases inspectable and totals trivial.
    var demandMisses = 0
    var stalledTurns = 0
    var prefetchDecodes = 0
    var rejectedPrefetches = 0

    static func += (lhs: inout Self, rhs: Self) {
        lhs.demandMisses += rhs.demandMisses
        lhs.stalledTurns += rhs.stalledTurns
        lhs.prefetchDecodes += rhs.prefetchDecodes
        lhs.rejectedPrefetches += rhs.rejectedPrefetches
    }
}

private struct ReplayCache {
    // A policy simulator, not another production cache. Retention rank is the
    // primary eviction key; access age breaks ties among equally ranked pages.
    let capacity: Int
    private var pages = Set<Int>()
    private var accessOrder = [Int]()
    private var retentionRanks = [Int: Int]()

    init(capacity: Int) {
        self.capacity = capacity
    }

    mutating func setRetention(_ retention: [Int]) {
        retentionRanks = Dictionary(
            uniqueKeysWithValues: retention.enumerated().map { ($1, $0) }
        )
    }

    mutating func access(_ page: Int) -> Bool {
        guard pages.contains(page) else { return false }
        accessOrder.removeAll { $0 == page }
        accessOrder.append(page)
        return true
    }

    mutating func insert(_ page: Int) -> Bool {
        if pages.remove(page) != nil {
            accessOrder.removeAll { $0 == page }
        }

        while pages.count >= capacity {
            let incomingRank = retentionRanks[page] ?? Int.max
            guard let victim = accessOrder.max(by: { rank($0) < rank($1) }),
                rank(victim) >= incomingRank
            else {
                return false
            }
            pages.remove(victim)
            accessOrder.removeAll { $0 == victim }
        }

        pages.insert(page)
        accessOrder.append(page)
        return true
    }

    private func rank(_ page: Int) -> Int {
        retentionRanks[page] ?? Int.max
    }
}
